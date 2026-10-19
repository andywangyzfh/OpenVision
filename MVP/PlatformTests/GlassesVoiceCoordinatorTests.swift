import OpenVisionCore
import SubscriptionCore
import UIKit
import XCTest

/// Actual VM + Inputs + photo + speech services and production binding. Only SDK/audio/model
/// effects and the queue are substituted; no login, hardware, recording or model request occurs.
final class GlassesVoiceCoordinatorTests: XCTestCase {
    @MainActor
    func testExplicitGestureVoiceCycleNeverRequestsCameraOrSendsAnImage() async throws {
        let rig = try JointRig()
        defer { rig.stop() }
        try await rig.armAndQueueSelect()
        XCTAssertEqual(rig.camera.permissionChecks, 0)
        await rig.queue.runNext()
        XCTAssertTrue(rig.model.speech.isListening)
        rig.speech.recognize?(SpeechRecognitionEvent(text: "你好", final: true))
        try await jointEventually { rig.speech.playbacks == 1 }
        XCTAssertEqual(rig.responses.turns.count, 1)
        XCTAssertTrue(rig.responses.turns[0].allSatisfy { $0.imageJPEG == nil })
        rig.speech.finish()
        try await jointEventually { rig.speech.listens == 2 }
        XCTAssertEqual(rig.camera.permissionChecks, 0)
        XCTAssertEqual(rig.camera.creates, 0)
        XCTAssertEqual(rig.camera.attaches, 0)
        XCTAssertEqual(rig.camera.streams, 0)
        XCTAssertEqual(rig.camera.captures, 0)
    }

    @MainActor
    func testQueuedGestureCannotSurviveDisarmAndRearm() async throws {
        let rig = try JointRig(); defer { rig.stop() }
        try await rig.armAndQueueSelect()
        let stopped = await rig.inputs.disarmAndWait()
        XCTAssertTrue(stopped)
        try await rig.arm()
        await rig.queue.runNext()
        XCTAssertEqual(rig.speech.authorizations, 0)
        XCTAssertEqual(rig.speech.listens, 0)
        XCTAssertEqual(rig.camera.permissionChecks, 0)
    }

    @MainActor
    func testQueuedGestureCannotSurviveAppStopWhileInputsStayArmed() async throws {
        let rig = try JointRig(); defer { rig.stop() }
        try await rig.armAndQueueSelect()
        rig.model.stop()
        XCTAssertTrue(rig.inputs.isArmed)
        await rig.queue.runNext()
        XCTAssertEqual(rig.speech.authorizations, 0)
        XCTAssertEqual(rig.speech.listens, 0)
    }

    @MainActor
    func testQueuedOldGestureCannotCancelANewerPhotoConfirmation() async throws {
        let rig = try JointRig(); defer { rig.stop() }
        try await rig.armAndQueueSelect()
        rig.model.draft = "一张明确请求的照片"
        rig.model.sendDraft(photo: true)
        let request = try XCTUnwrap(rig.model.pendingPhoto)
        await rig.queue.runNext()
        XCTAssertEqual(rig.model.pendingPhoto?.id, request.id)
        XCTAssertEqual(rig.speech.authorizations, 0)
        XCTAssertEqual(rig.camera.permissionChecks, 0)
        rig.model.cancelPhoto(requestID: request.id)
    }

    @MainActor
    func testSessionPauseDuringVoicePermissionCannotStartListeningLater() async throws {
        let rig = try JointRig(); defer { rig.stop() }
        rig.speech.holdAuthorization = true
        try await rig.armAndQueueSelect()
        let activation = Task { await rig.queue.runNext() }
        try await jointEventually { rig.speech.permissionWaiter != nil }
        rig.inputDriver.emit(.paused)
        try await jointEventually { !rig.inputs.isArmed && !rig.model.authorizingSpeech }
        rig.speech.resolveAuthorization()
        await activation.value
        XCTAssertEqual(rig.speech.listens, 0)
        XCTAssertEqual(rig.camera.permissionChecks, 0)
    }

    @MainActor
    func testInactiveSceneRevokesQueuedGestureAndDoesNotAutoRearm() async throws {
        let rig = try JointRig(); defer { rig.stop() }
        try await rig.armAndQueueSelect()
        rig.coordinator.setActive(false)
        await rig.queue.runNext()
        XCTAssertEqual(rig.speech.authorizations, 0)
        XCTAssertEqual(rig.speech.listens, 0)
        rig.coordinator.setActive(true)
        XCTAssertFalse(rig.inputs.isArmed)
        XCTAssertEqual(rig.camera.creates, 0)
    }

    @MainActor
    func testFailedInputsTeardownRejectsConfirmedPhotoBeforeCameraPermission() async throws {
        let rig = try JointRig(); defer { rig.inputDriver.stopSucceeds = true; rig.stop() }
        try await rig.arm()
        rig.inputDriver.stopSucceeds = false
        rig.model.draft = "明确请求一张照片"; rig.model.sendDraft(photo: true)
        let request = try XCTUnwrap(rig.model.pendingPhoto)
        rig.model.confirmPhoto(requestID: request.id)
        try await jointEventually { rig.inputDriver.stops > 0 && rig.model.pendingPhoto == nil }
        XCTAssertEqual(rig.camera.permissionChecks, 0)
        XCTAssertEqual(rig.camera.creates, 0)
        XCTAssertEqual(rig.responses.turns.count, 0)
    }

    @MainActor
    func testPositivePhotoWaitsForInputsCleanupAndConsumesOnlyOneCapture() async throws {
        let rig = try JointRig(); defer { rig.stop() }
        try await rig.arm()
        rig.model.draft = "本次确认的一张照片"; rig.model.sendDraft(photo: true)
        let request = try XCTUnwrap(rig.model.pendingPhoto)
        XCTAssertEqual(rig.camera.permissionChecks, 0)
        rig.model.confirmPhoto(requestID: request.id)
        rig.model.confirmPhoto(requestID: request.id)
        try await jointEventually { rig.speech.playbacks == 1 }
        XCTAssertFalse(rig.inputDriver.hasSession)
        XCTAssertEqual(rig.camera.overlaps, 0)
        XCTAssertEqual(rig.camera.permissionChecks, 1)
        XCTAssertEqual(rig.camera.captures, 1)
        XCTAssertEqual(rig.responses.turns.count, 1)
        XCTAssertNotNil(rig.responses.turns[0].last?.imageJPEG)
        rig.speech.finish()
        rig.model.draft = "普通文字"; rig.model.sendDraft()
        try await jointEventually { rig.speech.playbacks == 2 }
        XCTAssertTrue(rig.responses.turns[1].allSatisfy { $0.imageJPEG == nil })
        XCTAssertEqual(rig.camera.captures, 1)
    }

    @MainActor
    func testEarlyPhotoStopStillBlocksInputsUntilHardwareAndCaptureOwnerRelease() async throws {
        let rig = try JointRig(); defer { rig.camera.holdStop = false; rig.stop() }
        rig.camera.holdSessionStart = true; rig.camera.holdStop = true
        rig.model.draft = "明确照片"; rig.model.sendDraft(photo: true)
        let request = try XCTUnwrap(rig.model.pendingPhoto)
        rig.model.confirmPhoto(requestID: request.id)
        try await jointEventually { rig.camera.creates == 1 }
        XCTAssertFalse(rig.model.glasses.cameraActive)
        rig.model.stop()
        XCTAssertFalse(rig.model.busy)
        rig.inputs.setEnabled(true); await rig.inputs.arm()
        XCTAssertEqual(rig.inputDriver.starts, 0)
        XCTAssertFalse(rig.inputs.isArmed)
        rig.camera.stopped = true
        try await jointEventually { rig.model.glasses.canStartIndependentSession }
        await rig.inputs.arm()
        XCTAssertEqual(rig.inputDriver.starts, 1)
        XCTAssertTrue(rig.inputs.isArmed)
        XCTAssertEqual(rig.camera.attaches, 0)
    }
}

@MainActor
private func jointEventually(_ predicate: () -> Bool) async throws {
    let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(3))
    while !predicate() {
        guard clock.now < deadline else { throw JointFailure.timeout }
        await Task.yield()
    }
}
private enum JointFailure: Error { case timeout, image, overlap }

@MainActor private final class JointQueue {
    var jobs: [GlassesVoiceCoordinator.ActivationJob] = []
    func runNext() async { guard !jobs.isEmpty else { return }; await jobs.removeFirst()() }
}
@MainActor private final class JointResponses { var turns: [[PlanTurn]] = [] }

@MainActor private final class JointRig {
    let camera: JointCameraDriver
    let speech = JointSpeechDriver()
    let inputDriver = JointInputDriver()
    let inputs: GlassesInputService
    let model: ConversationViewModel
    let queue = JointQueue()
    let responses = JointResponses()
    let coordinator: GlassesVoiceCoordinator

    init() throws {
        camera = try JointCameraDriver()
        let photo = GlassesPhotoService(monitoring: false, sdkAvailable: true, driver: camera,
                                       timing: .init(sessionStart: 0.5, streamStart: 0.5, photo: 0.5, teardown: 0.08, poll: 0.002))
        inputs = GlassesInputService(driver: inputDriver, sdkAvailable: true)
        UserDefaults.standard.set("zh-CN", forKey: "mvp.language")
        model = ConversationViewModel(account: ChatGPTAccountService(), speechService: SpeechService(driver: speech), glassesService: photo)
        model.installLocalModelEffect(.init(model: .init(id: "joint-fixture", name: "Joint fixture")) { [responses] _, _, turns in
            responses.turns.append(turns); return "公开的本地测试回答。"
        })
        coordinator = GlassesVoiceCoordinator(model: model, inputs: inputs, enqueue: { [queue] job in queue.jobs.append(job) })
        camera.otherSessionPresent = { [inputDriver] in inputDriver.hasSession }
    }
    func arm() async throws {
        try await jointEventually { model.glasses.canStartIndependentSession }
        inputs.setEnabled(true); await inputs.arm()
        guard inputs.isArmed else {
            XCTFail("Inputs must actually own an armed session before the joint scenario")
            throw JointFailure.timeout
        }
    }
    func armAndQueueSelect() async throws {
        try await arm()
        inputDriver.emit(.sample(.init(source: .captouch, action: .select, timestampMilliseconds: 1_000)))
        try await jointEventually { queue.jobs.count == 1 }
    }
    func stop() { model.stop(); inputs.disarm() }
}

@MainActor private final class JointInputDriver: GlassesInputDriving {
    var hasSession = false
    var starts = 0, stops = 0
    var stopSucceeds = true
    private var stream: AsyncStream<GlassesInputDriverEvent>.Continuation?
    func start() async throws -> AsyncStream<GlassesInputDriverEvent> {
        starts += 1; hasSession = true
        let pair = AsyncStream<GlassesInputDriverEvent>.makeStream(); stream = pair.continuation
        return pair.stream
    }
    func stop() async -> Bool {
        stops += 1
        if stopSucceeds { hasSession = false; stream?.finish(); stream = nil }
        return stopSucceeds
    }
    func emit(_ event: GlassesInputDriverEvent) { stream?.yield(event) }
}

@MainActor private final class JointSpeechDriver: SpeechDriver {
    var onPlayback: ((UUID, SpeechPlaybackEvent) -> Void)?
    var onInputRoute: ((SpeechInputRouteEvent) -> Void)?
    var onInterruption: (() -> Void)?
    var authorizations = 0, listens = 0, playbacks = 0
    var holdAuthorization = false
    var permissionWaiter: CheckedContinuation<Bool, Never>?
    var recognize: (@MainActor (SpeechRecognitionEvent) -> Void)?
    private var playback: UUID?
    func authorize() async -> Bool {
        authorizations += 1
        if holdAuthorization { return await withCheckedContinuation { permissionWaiter = $0 } }
        return true
    }
    func resolveAuthorization() { permissionWaiter?.resume(returning: true); permissionWaiter = nil }
    func recognitionAvailable(language: ConversationLanguage) -> Bool { true }
    func startRecognition(language: ConversationLanguage, bluetoothMicrophone: Bool, receive: @escaping @MainActor (SpeechRecognitionEvent) -> Void) throws -> String {
        listens += 1; recognize = receive; return "Injected input — no microphone"
    }
    func stopRecognition() { recognize = nil }
    func voiceAvailable(language: ConversationLanguage) -> Bool { true }
    func startPlayback(text: String, language: ConversationLanguage, id: UUID) throws { playbacks += 1; playback = id }
    func stopPlayback() { playback = nil }
    func deactivateAudio() {}
    func finish() { if let playback { onPlayback?(playback, .finished) } }
}

@MainActor private final class JointCameraDriver: DATCameraDriver {
    var registered = true, deviceCount = 1
    var hasSession = false
    var holdSessionStart = false, holdStop = false, stopped = false
    var sessionStarted: Bool { hasSession && !holdSessionStart && !stopped }
    var sessionStopped: Bool { !hasSession || stopped }
    var connectionChanged: (@MainActor (Bool, Int) -> Void)?
    var permissionChecks = 0, creates = 0, attaches = 0, streams = 0, captures = 0, overlaps = 0
    var otherSessionPresent: () -> Bool = { false }
    private var event: (@MainActor @Sendable (DATCameraEvent) -> Void)?
    private let jpeg: Data
    init() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        guard let jpeg = image.jpegData(compressionQuality: 0.8) else { throw JointFailure.image }
        self.jpeg = jpeg
    }
    func register() async throws {}
    func installDeveloperComponent() async throws {}
    func authorizeCamera() async throws -> Bool { true }
    func handleRegistrationURL(_ url: URL) async throws {}
    func cameraPermissionGranted() async throws -> Bool { permissionChecks += 1; return true }
    func createAndStartSession() throws {
        if otherSessionPresent() { overlaps += 1; throw JointFailure.overlap }
        creates += 1; hasSession = true; stopped = false
    }
    func attachCamera(event: @escaping @MainActor @Sendable (DATCameraEvent) -> Void) throws { attaches += 1; self.event = event }
    func startStream() { streams += 1; event?(.streaming) }
    func capturePhoto() -> Bool { captures += 1; event?(.photo(jpeg)); return true }
    func stopHardware() { if !holdStop { stopped = true } }
    func releaseStoppedHardware() { hasSession = false; event = nil }
}
