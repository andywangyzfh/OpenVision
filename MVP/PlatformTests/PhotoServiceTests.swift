import ImageIO
import UIKit
import XCTest

/// Runs the production service and its UIKit re-encoding. The fake only stands in for the SDK's
/// state and callbacks; it deliberately keeps old callback closures to exercise session isolation.
final class PhotoServiceTests: XCTestCase {
    @MainActor
    func testGrantingCameraPermissionDoesNotAuthorizeOrStartAPhoto() async throws {
        let driver = FakeDATCameraDriver()
        let service = GlassesPhotoService(sdkAvailable: true, driver: driver, timing: fast)
        let granted = try await service.authorizeCamera()
        XCTAssertTrue(granted)
        do { _ = try await service.captureJPEG(intent: nil); XCTFail("OS permission substituted for per-photo confirmation") }
        catch { XCTAssertEqual(error as? GlassesPhotoService.PhotoFailure, .invalidIntent) }
        XCTAssertEqual(driver.permissionChecks, 0)
        XCTAssertEqual(driver.createCalls, 0)
        XCTAssertEqual(driver.captureCalls, 0)
    }
    @MainActor
    func testMissingRevokedAndSupersededIntentsRejectBeforePermissionOrHardware() async throws {
        let driver = FakeDATCameraDriver()
        let service = GlassesPhotoService(sdkAvailable: true, driver: driver, timing: fast)
        let cancelled = try service.authorizeSinglePhoto(requestID: UUID())
        service.revokeUnconsumedPhotoIntents()
        let replaced = try service.authorizeSinglePhoto(requestID: UUID())
        let current = try service.authorizeSinglePhoto(requestID: UUID())
        for intent in [nil, cancelled, replaced] {
            do { _ = try await service.captureJPEG(intent: intent); XCTFail("Missing/stale intent was accepted") }
            catch { XCTAssertEqual(error as? GlassesPhotoService.PhotoFailure, .invalidIntent) }
        }
        XCTAssertEqual(driver.permissionChecks, 0)
        XCTAssertEqual(driver.createCalls, 0)
        XCTAssertEqual(driver.captureCalls, 0)
        driver.photo = try fixture(.blue)
        _ = try await service.captureJPEG(intent: current)
        do { _ = try await service.captureJPEG(intent: current); XCTFail("Consumed intent was replayed") }
        catch { XCTAssertEqual(error as? GlassesPhotoService.PhotoFailure, .invalidIntent) }
        XCTAssertEqual(driver.permissionChecks, 1)
        XCTAssertEqual(driver.createCalls, 1)
        XCTAssertEqual(driver.captureCalls, 1)
    }

    @MainActor
    func testStopRevokesAnUnconsumedIntentBeforePermissionOrHardware() async throws {
        let driver = FakeDATCameraDriver()
        let service = GlassesPhotoService(sdkAvailable: true, driver: driver, timing: fast)
        let intent = try service.authorizeSinglePhoto(requestID: UUID())
        service.stop()
        do { _ = try await service.captureJPEG(intent: intent); XCTFail("Stopped intent was accepted") }
        catch { XCTAssertEqual(error as? GlassesPhotoService.PhotoFailure, .invalidIntent) }
        XCTAssertEqual(driver.permissionChecks, 0)
        XCTAssertEqual(driver.createCalls, 0)
        XCTAssertEqual(driver.captureCalls, 0)
    }
    @MainActor private var fast: GlassesPhotoService.Timing { GlassesPhotoService.Timing(sessionStart: 0.1, streamStart: 0.1, photo: 0.1, teardown: 0.08, poll: 0.002) }

    @MainActor
    func testIndependentSessionBlockedDuringPermissionAwaitEvenAfterStopCleanup() async throws {
        let driver = FakeDATCameraDriver(); driver.holdPermission = true
        let service = GlassesPhotoService(sdkAvailable: true, driver: driver, timing: fast)
        XCTAssertTrue(service.canStartIndependentSession)
        let capture = Task { try await confirmedCapture(service) }
        try await eventually { driver.permissionContinuation != nil }
        XCTAssertFalse(service.cameraActive)
        XCTAssertFalse(driver.hasSession)
        XCTAssertFalse(service.canStartIndependentSession)
        service.stop()
        try await eventually { driver.releaseCalls == 1 }
        XCTAssertFalse(service.canStartIndependentSession, "Permission await still owns the capture after cleanup")
        driver.permissionContinuation?.resume(returning: true); driver.permissionContinuation = nil
        do { _ = try await capture.value; XCTFail("Revoked capture completed") }
        catch is CancellationError {} catch GlassesPhotoService.PhotoFailure.intentRevoked {} catch { XCTFail("Unexpected \(error)") }
        XCTAssertTrue(service.canStartIndependentSession)
        XCTAssertEqual(driver.createCalls, 0)
    }

    @MainActor
    func testIndependentSessionBlockedBeforeCameraAttachAndUntilStopIsConfirmed() async throws {
        let driver = FakeDATCameraDriver(); driver.timeout = .session; driver.stopImmediately = false
        let service = GlassesPhotoService(sdkAvailable: true, driver: driver, timing: fast)
        XCTAssertTrue(service.canStartIndependentSession)
        let capture = Task { try await confirmedCapture(service) }
        try await eventually { driver.createCalls == 1 }
        XCTAssertFalse(service.cameraActive, "This regression must exercise the pre-attach window")
        XCTAssertTrue(driver.hasSession)
        XCTAssertFalse(service.canStartIndependentSession)
        service.stop()
        try await eventually { driver.stopCalls == 1 }
        XCTAssertFalse(service.canStartIndependentSession)
        driver.confirmStopped()
        do { _ = try await capture.value; XCTFail("Revoked capture completed") }
        catch is CancellationError {} catch GlassesPhotoService.PhotoFailure.intentRevoked {} catch { XCTFail("Unexpected \(error)") }
        XCTAssertFalse(driver.hasSession)
        XCTAssertTrue(service.canStartIndependentSession)
    }

    @MainActor
    func testDefaultUnavailableDriverNeverAccessesUnconfiguredWearables() async throws {
        let driver = WearablesCameraDriver()
        XCTAssertFalse(driver.registered)
        XCTAssertEqual(driver.deviceCount, 0)
        XCTAssertFalse(driver.hasSession)
        XCTAssertTrue(driver.sessionStopped)
        let actions: [@MainActor () async throws -> Void] = [
            { try await driver.register() },
            { try await driver.installDeveloperComponent() },
            { _ = try await driver.authorizeCamera() },
            { _ = try await driver.cameraPermissionGranted() },
            { try await driver.handleRegistrationURL(URL(string: "openvisionmvp://registration")!) }
        ]
        for action in actions {
            do { try await action(); XCTFail("Unavailable driver action should fail") }
            catch { XCTAssertEqual(error as? WearablesCameraDriver.DriverFailure, .sdkUnavailable) }
        }
        XCTAssertThrowsError(try driver.createAndStartSession()) { error in
            XCTAssertEqual(error as? WearablesCameraDriver.DriverFailure, .sdkUnavailable)
        }
        XCTAssertThrowsError(try driver.attachCamera { _ in }) { error in
            XCTAssertEqual(error as? WearablesCameraDriver.DriverFailure, .sdkUnavailable)
        }
        driver.startStream(); driver.stopHardware(); driver.releaseStoppedHardware()
        XCTAssertFalse(driver.capturePhoto())
        XCTAssertFalse(driver.hasSession)
    }

    @MainActor
    func testDefaultUnavailableServiceRejectsAllSDKOperationsAndStopIsSafe() async {
        let service = GlassesPhotoService()
        XCTAssertFalse(service.sdkAvailable)
        XCTAssertFalse(service.registered)
        XCTAssertEqual(service.deviceCount, 0)
        let actions: [@MainActor () async throws -> Void] = [
            { try await service.register() },
            { try await service.installDeveloperComponent() },
            { _ = try await service.authorizeCamera() },
            { try await service.handleRegistrationURL(URL(string: "openvisionmvp://registration")!) }
        ]
        for action in actions {
            do { try await action(); XCTFail("Unavailable service action should fail") }
            catch { XCTAssertEqual(error as? GlassesPhotoService.PhotoFailure, .sdkUnavailable) }
        }
        await expectFailure(.sdkUnavailable, service: service)
        service.stop()
        XCTAssertFalse(service.cameraActive)
    }

    @MainActor
    func testUnavailableStatusRejectsInjectedDriverBeforeStartingHardware() async {
        let driver = FakeDATCameraDriver()
        let service = GlassesPhotoService(sdkAvailable: false, driver: driver, timing: fast)
        await expectFailure(.sdkUnavailable, service: service)
        service.stop()
        XCTAssertEqual(driver.createCalls, 0)
        XCTAssertEqual(driver.stopCalls, 0)
        XCTAssertEqual(driver.releaseCalls, 0)
        XCTAssertFalse(service.registered)
        XCTAssertEqual(service.deviceCount, 0)
    }

    @MainActor
    func testFreshPhotoEachTurnAndOldCallbacksCannotPolluteNewTurn() async throws {
        let driver = FakeDATCameraDriver()
        let service = GlassesPhotoService(sdkAvailable: true, driver: driver, timing: fast)
        driver.photo = try fixture(.red)
        let first = try await confirmedCapture(service)
        let old = try XCTUnwrap(driver.callbacks.first)
        driver.photo = nil
        let secondTask = Task { try await confirmedCapture(service) }
        try await eventually { driver.captureCalls == 2 }
        old(.photo(try fixture(.red)))
        old(.failure)
        // A stale callback must not complete/fail B. Deliver B's fresh image on its own listener.
        driver.callbacks.last?(.photo(try fixture(.blue)))
        let second = try await secondTask.value
        XCTAssertNotEqual(first, second)
        try assertColor(first, red: true)
        try assertColor(second, red: false)
        XCTAssertEqual(driver.createCalls, 2)
        XCTAssertEqual(driver.releaseCalls, 2)
        XCTAssertFalse(service.cameraActive)
        XCTAssertFalse(driver.hasSession)
    }

    @MainActor
    func testProductionReencodingBoundsPixelsMakesJPEGAndStripsGPS() async throws {
        let driver = FakeDATCameraDriver()
        driver.photo = try fixture(.red, size: CGSize(width: 2560, height: 800), gps: true)
        let input = try XCTUnwrap(CGImageSourceCreateWithData(driver.photo! as CFData, nil))
        let inputProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [String: Any])
        XCTAssertNotNil(inputProperties[kCGImagePropertyGPSDictionary as String])
        let output = try await confirmedCapture(GlassesPhotoService(sdkAvailable: true, driver: driver, timing: fast))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, 1280)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight as String] as? Int, 400)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
        XCTAssertLessThanOrEqual(output.count, 4_000_000)
    }

    @MainActor
    func testNoConnectedGlassesDoesNotStartHardware() async {
        for registered in [false, true] {
            let driver = FakeDATCameraDriver(); driver.registered = registered; driver.deviceCount = 0
            await expectFailure(.noGlasses, service: GlassesPhotoService(sdkAvailable: true, driver: driver, timing: fast))
            XCTAssertEqual(driver.createCalls, 0)
            XCTAssertFalse(driver.hasSession)
        }
    }

    @MainActor
    func testDeniedPermissionDoesNotStartHardwareAndCleansOperation() async {
        let driver = FakeDATCameraDriver(); driver.permission = false
        let service = GlassesPhotoService(sdkAvailable: true, driver: driver, timing: fast)
        await expectFailure(.permission, service: service)
        XCTAssertEqual(driver.createCalls, 0)
        XCTAssertFalse(service.cameraActive)
        // Denial must release operation ownership, allowing a later explicit request.
        driver.permission = true
        driver.photo = try? fixture(.blue)
        do { _ = try await confirmedCapture(service) } catch { XCTFail("Retry failed: \(error)") }
        XCTAssertEqual(driver.createCalls, 1)
    }

    @MainActor
    func testStartAttachCaptureAndStreamErrorsCleanHardware() async throws {
        for failure in FakeDATCameraDriver.FailurePoint.allCases {
            let driver = FakeDATCameraDriver(); driver.failure = failure; driver.photo = try fixture(.red)
            let service = GlassesPhotoService(sdkAvailable: true, driver: driver, timing: fast)
            do { _ = try await confirmedCapture(service); XCTFail("Expected \(failure)") }
            catch { /* driver errors and capture errors are surfaced to the caller */ }
            XCTAssertFalse(driver.hasSession, "\(failure)")
            XCTAssertFalse(service.cameraActive, "\(failure)")
            XCTAssertEqual(driver.releaseCalls, 1, "\(failure)")
        }
    }

    @MainActor
    func testEmptyAndDamagedImageDataFailAndClean() async {
        for data in [Data(), Data("not an image".utf8)] {
            let driver = FakeDATCameraDriver(); driver.photo = data
            let service = GlassesPhotoService(sdkAvailable: true, driver: driver, timing: fast)
            await expectFailure(.capture, service: service)
            XCTAssertFalse(driver.hasSession)
            XCTAssertFalse(service.cameraActive)
            XCTAssertEqual(driver.releaseCalls, 1)
        }
    }

    @MainActor
    func testSessionStreamAndPhotoTimeoutsClean() async {
        for stage in FakeDATCameraDriver.TimeoutStage.allCases {
            let driver = FakeDATCameraDriver(); driver.timeout = stage
            let service = GlassesPhotoService(sdkAvailable: true, driver: driver, timing: fast)
            await expectFailure(.capture, service: service)
            XCTAssertFalse(driver.hasSession, "\(stage)")
            XCTAssertFalse(service.cameraActive, "\(stage)")
            XCTAssertEqual(driver.releaseCalls, 1, "\(stage)")
        }
    }

    @MainActor
    func testCancellationDuringPermissionAwaitNeverStartsHardware() async throws {
        for cancelTask in [false, true] {
            let driver = FakeDATCameraDriver(); driver.holdPermission = true
            let service = GlassesPhotoService(sdkAvailable: true, driver: driver, timing: fast)
            let task = Task { try await confirmedCapture(service) }
            try await eventually { driver.permissionContinuation != nil }
            if cancelTask { task.cancel() }
            else { service.stop() } // UI Stop also invalidates an uncancelled permission await.
            driver.permissionContinuation?.resume(returning: true); driver.permissionContinuation = nil
            do { _ = try await task.value; XCTFail("Expected cancellation") }
            catch is CancellationError {} catch GlassesPhotoService.PhotoFailure.intentRevoked {} catch { XCTFail("Unexpected \(error)") }
            XCTAssertEqual(driver.createCalls, 0)
            XCTAssertFalse(service.cameraActive)
        }
    }

    @MainActor
    func testCancellationYieldsAndWaitsForConfirmedTeardown() async throws {
        let driver = FakeDATCameraDriver(); driver.photo = nil; driver.stopImmediately = false
        let service = GlassesPhotoService(sdkAvailable: true, driver: driver, timing: fast)
        var finished = false
        let task = Task { defer { finished = true }; return try await confirmedCapture(service) }
        try await eventually { driver.captureCalls == 1 }
        task.cancel()
        try await eventually { driver.stopCalls == 1 }
        // The main actor can execute this timer while canceled capture waits for detached cleanup.
        try await Task.sleep(for: .milliseconds(6))
        XCTAssertFalse(finished)
        XCTAssertTrue(service.cameraActive)
        XCTAssertEqual(driver.releaseCalls, 0)
        driver.confirmStopped()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch GlassesPhotoService.PhotoFailure.intentRevoked {} catch { XCTFail("Unexpected \(error)") }
        XCTAssertTrue(finished)
        XCTAssertFalse(service.cameraActive)
        XCTAssertEqual(driver.releaseCalls, 1)
    }

    @MainActor
    func testNewCaptureCannotStartBeforePriorCleanupCompletes() async throws {
        let driver = FakeDATCameraDriver(); driver.photo = try fixture(.red); driver.stopImmediately = false
        let service = GlassesPhotoService(sdkAvailable: true, driver: driver, timing: fast)
        let first = Task { try await confirmedCapture(service) }
        try await eventually { driver.stopCalls == 1 }
        await expectFailure(.busy, service: service)
        XCTAssertEqual(driver.createCalls, 1)
        XCTAssertEqual(driver.releaseCalls, 0)
        driver.confirmStopped()
        _ = try await first.value
        XCTAssertEqual(driver.createCalls, 1)
    }

    @MainActor
    func testTeardownTimeoutRetainsHandlesThenNextRequestRetriesCleanupFirst() async throws {
        let driver = FakeDATCameraDriver(); driver.photo = try fixture(.red); driver.stopImmediately = false
        let service = GlassesPhotoService(sdkAvailable: true, driver: driver, timing: fast)
        await expectFailure(.teardown, service: service)
        XCTAssertTrue(driver.hasSession)
        XCTAssertTrue(service.cameraActive)
        XCTAssertFalse(service.canStartIndependentSession)
        XCTAssertEqual(driver.createCalls, 1)
        XCTAssertEqual(driver.releaseCalls, 0)
        driver.stopImmediately = true
        driver.photo = try fixture(.blue)
        let output = try await confirmedCapture(service)
        try assertColor(output, red: false)
        XCTAssertEqual(driver.createCalls, 2)
        XCTAssertFalse(driver.overlappingSession)
        XCTAssertFalse(driver.hasSession)
        XCTAssertFalse(service.cameraActive)
        XCTAssertTrue(service.canStartIndependentSession)
        XCTAssertEqual(driver.releaseCalls, 2) // old timed-out session, then the new session
    }

    @MainActor
    private func confirmedCapture(_ service: GlassesPhotoService) async throws -> Data {
        let intent = try service.authorizeSinglePhoto(requestID: UUID())
        return try await service.captureJPEG(intent: intent)
    }

    @MainActor
    private func expectFailure(_ expected: GlassesPhotoService.PhotoFailure, service: GlassesPhotoService, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await confirmedCapture(service); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? GlassesPhotoService.PhotoFailure, expected, file: file, line: line) }
    }

    @MainActor
    private func eventually(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let clock = ContinuousClock(); let deadline = clock.now.advanced(by: .seconds(1))
        while !predicate() {
            guard clock.now < deadline else { XCTFail("Condition timed out", file: file, line: line); throw TestFailure.timeout }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @MainActor
    private func fixture(_ color: UIColor, size: CGSize = CGSize(width: 32, height: 16), gps: Bool = false) throws -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill(); context.fill(CGRect(origin: .zero, size: size))
        }
        let jpeg = try XCTUnwrap(image.jpegData(compressionQuality: 0.95))
        guard gps else { return jpeg }
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImageFromSource(destination, source, 0, [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.0, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 122.0, kCGImagePropertyGPSLongitudeRef: "W"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @MainActor
    private func assertColor(_ data: Data, red: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let image = try XCTUnwrap(UIImage(data: data)?.cgImage, file: file, line: line)
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), file: file, line: line)
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertGreaterThan(pixel[red ? 0 : 2], 180, file: file, line: line)
        XCTAssertLessThan(pixel[red ? 2 : 0], 60, file: file, line: line)
    }
    enum TestFailure: Error { case timeout }
}

@MainActor
private final class FakeDATCameraDriver: DATCameraDriver {
    enum FailurePoint: CaseIterable { case sessionStart, attachCamera, capturePhoto, stream }
    enum TimeoutStage: CaseIterable { case session, stream, photo }
    enum Failure: Error { case sdk }
    var registered = true
    var deviceCount = 1
    var hasSession = false
    var sessionStarted = false
    var sessionStopped = true
    var connectionChanged: (@MainActor (Bool, Int) -> Void)?
    var callbacks: [@MainActor @Sendable (DATCameraEvent) -> Void] = []
    var permission = true
    var permissionChecks = 0
    var holdPermission = false
    var permissionContinuation: CheckedContinuation<Bool, Never>?
    var photo: Data?
    var failure: FailurePoint?
    var timeout: TimeoutStage?
    var stopImmediately = true
    var createCalls = 0
    var captureCalls = 0
    var stopCalls = 0
    var releaseCalls = 0
    var overlappingSession = false

    func register() async throws {}
    func installDeveloperComponent() async throws {}
    func authorizeCamera() async throws -> Bool { permission }
    func handleRegistrationURL(_ url: URL) async throws {}
    func cameraPermissionGranted() async throws -> Bool {
        permissionChecks += 1
        if holdPermission { return await withCheckedContinuation { permissionContinuation = $0 } }
        return permission
    }
    func createAndStartSession() throws {
        if hasSession { overlappingSession = true; throw Failure.sdk }
        createCalls += 1; hasSession = true; sessionStopped = false
        if failure == .sessionStart { throw Failure.sdk }
        sessionStarted = timeout != .session
    }
    func attachCamera(event: @escaping @MainActor @Sendable (DATCameraEvent) -> Void) throws {
        if failure == .attachCamera { throw Failure.sdk }
        callbacks.append(event)
    }
    func startStream() {
        if failure == .stream { callbacks.last?(.failure) }
        else if timeout != .stream { callbacks.last?(.streaming) }
    }
    func capturePhoto() -> Bool {
        captureCalls += 1
        if failure == .capturePhoto { return false }
        if timeout != .photo, let photo { callbacks.last?(.photo(photo)) }
        return true
    }
    func stopHardware() { stopCalls += 1; if stopImmediately { confirmStopped() } }
    func confirmStopped() { sessionStopped = true; sessionStarted = false }
    func releaseStoppedHardware() {
        precondition(sessionStopped)
        releaseCalls += 1; hasSession = false
    }
}
