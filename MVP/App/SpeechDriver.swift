import AVFoundation
import Foundation
import OpenVisionCore
import Speech

struct SpeechRecognitionEvent: Sendable {
    let text: String?
    var final = false
    var failed = false
}

enum SpeechPlaybackEvent: Sendable { case finished, cancelled }
enum SpeechInputRouteEvent: Sendable { case changed(String), lost }

/// Only platform effects are replaced in tests. SpeechService owns turn/timer identities.
@MainActor
protocol SpeechDriver: AnyObject {
    var onPlayback: ((UUID, SpeechPlaybackEvent) -> Void)? { get set }
    var onInputRoute: ((SpeechInputRouteEvent) -> Void)? { get set }
    var onInterruption: (() -> Void)? { get set }
    func authorize() async -> Bool
    func recognitionAvailable(language: ConversationLanguage) -> Bool
    func startRecognition(language: ConversationLanguage, bluetoothMicrophone: Bool,
                          receive: @escaping @MainActor (SpeechRecognitionEvent) -> Void) throws -> String
    func stopRecognition()
    func voiceAvailable(language: ConversationLanguage) -> Bool
    func startPlayback(text: String, language: ConversationLanguage, id: UUID) throws
    func stopPlayback()
    func deactivateAudio()
}

@MainActor
final class AppleSpeechDriver: NSObject, SpeechDriver, AVSpeechSynthesizerDelegate {
    var onPlayback: ((UUID, SpeechPlaybackEvent) -> Void)?
    var onInputRoute: ((SpeechInputRouteEvent) -> Void)?
    var onInterruption: (() -> Void)?
    private let engine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var tapInstalled = false
    private var selectedInputUID: String?
    private var routeObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private nonisolated let playbackIDs = SpeechPlaybackIDs()

    override init() {
        super.init()
        synthesizer.delegate = self
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.verifyInputRoute() }
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let began = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                == AVAudioSession.InterruptionType.began.rawValue
            guard began else { return }
            Task { @MainActor [weak self] in self?.onInterruption?() }
        }
    }

    func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        let microphone = await AVAudioApplication.requestRecordPermission()
        return speech && microphone
    }

    func recognitionAvailable(language: ConversationLanguage) -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: language.recognitionLocaleID))?.isAvailable == true
    }

    func startRecognition(language: ConversationLanguage, bluetoothMicrophone: Bool,
                          receive: @escaping @MainActor (SpeechRecognitionEvent) -> Void) throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language.recognitionLocaleID)), recognizer.isAvailable else {
            throw SpeechService.SpeechFailure.unavailable
        }
        var started = false
        defer { if !started { stopRecognition() } }
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
        try audio.setActive(true)
        let selected: AVAudioSessionPortDescription
        if bluetoothMicrophone {
            let inputs = audio.availableInputs?.filter { $0.portType == .bluetoothHFP } ?? []
            if let current = audio.currentRoute.inputs.first(where: { $0.portType == .bluetoothHFP }),
               let input = inputs.first(where: { $0.uid == current.uid }) { selected = input }
            else if inputs.count == 1, let input = inputs.first { selected = input }
            else {
                throw inputs.isEmpty ? SpeechService.SpeechFailure.bluetoothMicrophoneMissing : SpeechService.SpeechFailure.ambiguousBluetoothInput
            }
        } else {
            guard let input = audio.availableInputs?.first(where: { $0.portType == .builtInMic }) else { throw SpeechService.SpeechFailure.unavailable }
            selected = input
        }
        try audio.setPreferredInput(selected)
        guard let actual = audio.currentRoute.inputs.first(where: { $0.uid == selected.uid }) else { throw SpeechService.SpeechFailure.unavailable }
        selectedInputUID = actual.uid
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true; request.taskHint = .dictation
        self.request = request
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechService.SpeechFailure.unavailable }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        tapInstalled = true
        recognitionTask = recognizer.recognitionTask(with: request) { result, error in
            let event = SpeechRecognitionEvent(text: result?.bestTranscription.formattedString,
                                               final: result?.isFinal ?? false, failed: error != nil)
            Task { @MainActor in receive(event) }
        }
        engine.prepare()
        try engine.start()
        started = true
        return actual.portName
    }

    func stopRecognition() {
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio(); recognitionTask?.cancel()
        request = nil; recognitionTask = nil; recognizer = nil; selectedInputUID = nil
        deactivateAudio()
    }

    private func verifyInputRoute() {
        guard let selectedInputUID else { return }
        if let actual = AVAudioSession.sharedInstance().currentRoute.inputs.first(where: { $0.uid == selectedInputUID }) {
            onInputRoute?(.changed(actual.portName))
        } else { onInputRoute?(.lost) }
    }

    func voiceAvailable(language: ConversationLanguage) -> Bool {
        AVSpeechSynthesisVoice(language: language.speechLocaleID) != nil
    }

    func startPlayback(text: String, language: ConversationLanguage, id: UUID) throws {
        guard let voice = AVSpeechSynthesisVoice(language: language.speechLocaleID) else { throw SpeechService.SpeechFailure.voiceMissing }
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback, mode: .spokenAudio)
        try audio.setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice; utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        playbackIDs.insert(id, for: ObjectIdentifier(utterance))
        synthesizer.speak(utterance)
    }

    func stopPlayback() { playbackIDs.removeAll(); synthesizer.stopSpeaking(at: .immediate) }
    func deactivateAudio() { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard let id = playbackIDs.take(ObjectIdentifier(utterance)) else { return }
        Task { @MainActor [weak self] in self?.onPlayback?(id, .finished) }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard let id = playbackIDs.take(ObjectIdentifier(utterance)) else { return }
        Task { @MainActor [weak self] in self?.onPlayback?(id, .cancelled) }
    }
}

/// Resolve object identity to the turn UUID before crossing from a delegate's calling thread.
private final class SpeechPlaybackIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ObjectIdentifier: UUID] = [:]
    func insert(_ id: UUID, for object: ObjectIdentifier) { lock.lock(); defer { lock.unlock() }; values[object] = id }
    func take(_ object: ObjectIdentifier) -> UUID? { lock.lock(); defer { lock.unlock() }; return values.removeValue(forKey: object) }
    func removeAll() { lock.lock(); defer { lock.unlock() }; values.removeAll() }
}
