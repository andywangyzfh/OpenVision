import Foundation
import OpenVisionCore
import XCTest

/// Runs the production SpeechService state machine. Platform speech quality, real routes and
/// hardware resource release require Gate 2; this driver records only requested software effects.
final class SpeechServiceTests: XCTestCase {
    @MainActor
    func testAuthorizationDenialAndUnavailableRecognitionDoNotStart() async throws {
        let driver = FakeSpeechDriver()
        let service = SpeechService(driver: driver)
        driver.authorized = false
        let denied = await service.authorize()
        XCTAssertFalse(denied)
        XCTAssertTrue(driver.recognitionStarts.isEmpty)
        driver.authorized = true
        let allowed = await service.authorize()
        XCTAssertTrue(allowed)
        driver.available = false
        XCTAssertThrowsError(try service.listen(language: .chinese, glassesMicrophone: true)) {
            XCTAssertEqual($0 as? SpeechService.SpeechFailure, .unavailable)
        }
        XCTAssertFalse(service.isListening)
        XCTAssertTrue(driver.recognitionStarts.isEmpty)
    }

    @MainActor
    func testSelectedLanguageAndInputPreferenceReachDriver() throws {
        let driver = FakeSpeechDriver()
        let service = SpeechService(driver: driver)
        defer { service.stopAll() }
        try service.listen(language: .chinese, glassesMicrophone: true)
        XCTAssertEqual(service.inputName, "Fixture Bluetooth")
        try service.listen(language: .english, glassesMicrophone: false)
        XCTAssertEqual(driver.recognitionStarts.map(\.language), [.chinese, .english])
        XCTAssertEqual(driver.recognitionStarts.map(\.bluetooth), [true, false])
        XCTAssertEqual(service.inputName, "Fixture iPhone")
    }

    @MainActor
    func testShortMandarinFinalCommitsExactlyOnceAndIgnoresDuplicateFinal() throws {
        let driver = FakeSpeechDriver()
        let service = SpeechService(driver: driver)
        defer { service.stopAll() }
        var received: [String] = []
        service.onUtterance = { received.append($0) }
        for word in ["你好", "继续", "好", "是"] {
            try service.listen(language: .chinese, glassesMicrophone: true)
            let callback = try XCTUnwrap(driver.recognitionCallbacks.last)
            callback(.init(text: word, final: true))
            callback(.init(text: word, final: true))
            XCTAssertFalse(service.isListening)
            XCTAssertFalse(driver.recording)
        }
        XCTAssertEqual(received, ["你好", "继续", "好", "是"])
    }

    @MainActor
    func testPartialMandarinCommitsOnInjectedSilenceTimer() async throws {
        let driver = FakeSpeechDriver()
        let clock = SpeechTestClock()
        let service = SpeechService(driver: driver, silenceSleep: { await clock.sleep() })
        defer { service.stopAll(); Task { await clock.releaseAll() } }
        var received: [String] = []
        service.onUtterance = { received.append($0) }
        try service.listen(language: .chinese, glassesMicrophone: true)
        driver.recognitionCallbacks[0](.init(text: "好"))
        try await waitForSpeech { await clock.count == 1 }
        await clock.releaseFirst()
        try await waitForSpeech { received == ["好"] }
        XCTAssertFalse(service.isListening)
        XCTAssertFalse(driver.recording)
    }

    @MainActor
    func testCancelledOldTimerAndCallbackCannotCommitNewListeningTurn() async throws {
        let driver = FakeSpeechDriver()
        let clock = SpeechTestClock()
        let service = SpeechService(driver: driver, silenceSleep: { await clock.sleep() })
        defer { service.stopAll(); Task { await clock.releaseAll() } }
        var received: [String] = []
        service.onUtterance = { received.append($0) }
        try service.listen(language: .chinese, glassesMicrophone: true)
        let old = driver.recognitionCallbacks[0]
        old(.init(text: "旧问题"))
        try await waitForSpeech { await clock.count == 1 }
        service.stopAll()
        try service.listen(language: .chinese, glassesMicrophone: true)
        driver.recognitionCallbacks[1](.init(text: "新问题"))
        try await waitForSpeech { await clock.count == 2 }
        old(.init(text: "旧结果", final: true))
        await clock.releaseFirst()
        await speechDrain()
        XCTAssertTrue(received.isEmpty)
        XCTAssertTrue(service.isListening)
        XCTAssertEqual(service.transcript, "新问题")
        await clock.releaseFirst()
        try await waitForSpeech { received == ["新问题"] }
    }

    @MainActor
    func testPlaybackStopsRecognitionAndIgnoresItsOldTranscript() throws {
        let driver = FakeSpeechDriver()
        let service = SpeechService(driver: driver)
        defer { service.stopAll() }
        var received: [String] = []
        service.onUtterance = { received.append($0) }
        try service.listen(language: .chinese, glassesMicrophone: true)
        let old = driver.recognitionCallbacks[0]
        try service.speak("这是我的回答。停止！？Hello.?!", language: .chinese)
        old(.init(text: "这是我的回答。停止！？Hello.?!", final: true))
        XCTAssertTrue(received.isEmpty)
        XCTAssertFalse(service.isListening)
        XCTAssertFalse(driver.recording)
        XCTAssertTrue(driver.playing)
        XCTAssertEqual(driver.playbacks.last?.text, "这是我的回答。停止！？Hello.?!")
        XCTAssertEqual(driver.playbacks.last?.language, .chinese)
    }

    @MainActor
    func testOldPlaybackFinishAndCancelCannotEndNewPlayback() throws {
        let driver = FakeSpeechDriver()
        let service = SpeechService(driver: driver)
        defer { service.stopAll() }
        var finishes = 0, failures = 0
        service.onSpeechFinished = { finishes += 1 }; service.onFailure = { failures += 1 }
        try service.speak("old", language: .english)
        let old = try XCTUnwrap(driver.playbacks.last?.id)
        service.stopAll()
        try service.speak("new", language: .english)
        let current = try XCTUnwrap(driver.playbacks.last?.id)
        let deactivations = driver.deactivations
        driver.onPlayback?(old, .finished); driver.onPlayback?(old, .cancelled)
        XCTAssertEqual(finishes, 0); XCTAssertEqual(failures, 0)
        XCTAssertEqual(driver.deactivations, deactivations)
        XCTAssertTrue(driver.playing)
        driver.onPlayback?(current, .finished)
        XCTAssertEqual(finishes, 1); XCTAssertEqual(failures, 0)
        XCTAssertFalse(driver.audioActive)
        driver.onPlayback?(current, .finished)
        XCTAssertEqual(finishes, 1)
    }

    @MainActor
    func testStopReleasesEffectsAndAllowsExplicitRestart() throws {
        let driver = FakeSpeechDriver()
        let service = SpeechService(driver: driver)
        var failures = 0
        service.onFailure = { failures += 1 }
        try service.listen(language: .chinese, glassesMicrophone: true)
        service.stopAll()
        XCTAssertFalse(service.isListening); XCTAssertFalse(driver.recording)
        XCTAssertFalse(driver.playing); XCTAssertFalse(driver.audioActive)
        XCTAssertEqual(service.inputName, "")
        try service.speak("first", language: .english)
        let old = try XCTUnwrap(driver.playbacks.last?.id)
        service.stopAll(); driver.onPlayback?(old, .cancelled)
        XCTAssertEqual(failures, 0)
        try service.listen(language: .english, glassesMicrophone: false)
        XCTAssertTrue(service.isListening); XCTAssertTrue(driver.recording)
        service.stopAll()
    }

    @MainActor
    func testMissingVoiceAndStartupFailuresReleaseEffects() throws {
        let driver = FakeSpeechDriver()
        let service = SpeechService(driver: driver)
        driver.hasVoice = false
        XCTAssertThrowsError(try service.speak("你好", language: .chinese)) {
            XCTAssertEqual($0 as? SpeechService.SpeechFailure, .voiceMissing)
        }
        XCTAssertTrue(driver.playbacks.isEmpty)
        driver.recognitionError = .bluetoothMicrophoneMissing
        XCTAssertThrowsError(try service.listen(language: .chinese, glassesMicrophone: true))
        XCTAssertFalse(service.isListening); XCTAssertFalse(driver.recording); XCTAssertFalse(driver.audioActive)
        driver.recognitionError = nil; driver.hasVoice = true; driver.playbackFails = true
        XCTAssertThrowsError(try service.speak("你好", language: .chinese))
        XCTAssertFalse(driver.audioActive)
        driver.playbackFails = false
        try service.speak("retry", language: .english)
        XCTAssertTrue(driver.playing)
        service.stopAll()
    }

    @MainActor
    func testRecognitionFailureAndEmptyFinalDoNotLeaveDeadListeningState() throws {
        let driver = FakeSpeechDriver()
        let service = SpeechService(driver: driver)
        var received: [String] = [], failures = 0
        service.onUtterance = { received.append($0) }; service.onFailure = { failures += 1 }
        try service.listen(language: .chinese, glassesMicrophone: true)
        driver.recognitionCallbacks[0](.init(text: nil, failed: true))
        XCTAssertFalse(service.isListening); XCTAssertEqual(failures, 1)
        try service.listen(language: .english, glassesMicrophone: false)
        driver.recognitionCallbacks[1](.init(text: " \n ", final: true))
        XCTAssertFalse(service.isListening); XCTAssertEqual(failures, 2)
        XCTAssertTrue(received.isEmpty); XCTAssertFalse(driver.recording)
    }

    @MainActor
    func testRouteLossStopsAndChangedNameIsDisplayedOnlyWhileListening() throws {
        let driver = FakeSpeechDriver()
        let service = SpeechService(driver: driver)
        var failures = 0
        service.onFailure = { failures += 1 }
        try service.listen(language: .chinese, glassesMicrophone: true)
        driver.onInputRoute?(.changed("Fixture renamed input"))
        XCTAssertEqual(service.inputName, "Fixture renamed input")
        driver.onInputRoute?(.lost)
        XCTAssertFalse(service.isListening); XCTAssertFalse(driver.recording); XCTAssertFalse(driver.audioActive)
        XCTAssertEqual(failures, 1)
        driver.onInputRoute?(.changed("stale route"))
        XCTAssertEqual(service.inputName, "")
        try service.listen(language: .english, glassesMicrophone: false)
        XCTAssertTrue(service.isListening)
        service.stopAll()
    }

    @MainActor
    func testInterruptionStopsListeningAndPlaybackWithoutAutoResume() throws {
        let driver = FakeSpeechDriver()
        let service = SpeechService(driver: driver)
        var failures = 0, finishes = 0
        service.onFailure = { failures += 1 }; service.onSpeechFinished = { finishes += 1 }
        try service.listen(language: .chinese, glassesMicrophone: true)
        driver.onInterruption?()
        XCTAssertFalse(service.isListening); XCTAssertFalse(driver.recording); XCTAssertFalse(driver.audioActive)
        try service.speak("你好", language: .chinese)
        let old = try XCTUnwrap(driver.playbacks.last?.id)
        driver.onInterruption?(); driver.onPlayback?(old, .finished)
        XCTAssertFalse(driver.playing); XCTAssertFalse(driver.audioActive)
        XCTAssertEqual(failures, 2); XCTAssertEqual(finishes, 0)
        XCTAssertEqual(driver.recognitionStarts.count, 1)
    }

    @MainActor
    func testUnexpectedPlaybackCancelFailsOnceAndReleasesAudio() throws {
        let driver = FakeSpeechDriver()
        let service = SpeechService(driver: driver)
        var failures = 0
        service.onFailure = { failures += 1 }
        try service.speak("你好", language: .chinese)
        let id = try XCTUnwrap(driver.playbacks.last?.id)
        driver.onPlayback?(id, .cancelled); driver.onPlayback?(id, .cancelled)
        XCTAssertEqual(failures, 1)
        XCTAssertFalse(driver.playing); XCTAssertFalse(driver.audioActive)
    }
}

@MainActor
private final class FakeSpeechDriver: SpeechDriver {
    struct Start { let language: ConversationLanguage; let bluetooth: Bool }
    struct Playback { let text: String; let language: ConversationLanguage; let id: UUID }
    var onPlayback: ((UUID, SpeechPlaybackEvent) -> Void)?
    var onInputRoute: ((SpeechInputRouteEvent) -> Void)?
    var onInterruption: (() -> Void)?
    var authorized = true, available = true, hasVoice = true, playbackFails = false
    var recording = false, playing = false, audioActive = false
    var deactivations = 0
    var recognitionError: SpeechService.SpeechFailure?
    var recognitionStarts: [Start] = []
    var recognitionCallbacks: [@MainActor (SpeechRecognitionEvent) -> Void] = []
    var playbacks: [Playback] = []
    func authorize() async -> Bool { authorized }
    func recognitionAvailable(language: ConversationLanguage) -> Bool { available }
    func startRecognition(language: ConversationLanguage, bluetoothMicrophone: Bool,
                          receive: @escaping @MainActor (SpeechRecognitionEvent) -> Void) throws -> String {
        recording = true; audioActive = true
        if let recognitionError { throw recognitionError }
        recognitionStarts.append(.init(language: language, bluetooth: bluetoothMicrophone))
        recognitionCallbacks.append(receive)
        return bluetoothMicrophone ? "Fixture Bluetooth" : "Fixture iPhone"
    }
    func stopRecognition() { recording = false; deactivateAudio() }
    func voiceAvailable(language: ConversationLanguage) -> Bool { hasVoice }
    func startPlayback(text: String, language: ConversationLanguage, id: UUID) throws {
        audioActive = true
        if playbackFails { throw SpeechService.SpeechFailure.unavailable }
        playbacks.append(.init(text: text, language: language, id: id)); playing = true
    }
    func stopPlayback() { playing = false }
    func deactivateAudio() { audioActive = false; deactivations += 1 }
}

private actor SpeechTestClock {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    var count: Int { continuations.count }
    func sleep() async { await withCheckedContinuation { continuations.append($0) } }
    func releaseFirst() { if !continuations.isEmpty { continuations.removeFirst().resume() } }
    func releaseAll() { let pending = continuations; continuations.removeAll(); pending.forEach { $0.resume() } }
}

@MainActor
private func waitForSpeech(_ condition: @MainActor () async -> Bool) async throws {
    for _ in 0..<500 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    XCTFail("Timed out waiting for the production speech controller")
    throw SpeechService.SpeechFailure.unavailable
}

@MainActor
private func speechDrain() async {
    for _ in 0..<20 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(5))
}
