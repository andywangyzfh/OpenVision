import AVFoundation
import Combine
import OpenVisionCore
import Speech

/// Foreground conversation only. Recognition is stopped before TTS and before DAT starts.
@MainActor
final class SpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var transcript = ""
    @Published private(set) var inputName = ""
    @Published private(set) var isListening = false
    var onUtterance: ((String) -> Void)?
    var onSpeechFinished: (() -> Void)?
    var onFailure: (() -> Void)?
    private let engine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTask: Task<Void, Never>?
    private var listenID = UUID()
    private var tapInstalled = false
    private var committed = false
    private var activeUtteranceID: ObjectIdentifier?
    private var selectedInputUID: String?
    private var routeObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?

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
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stopAll()
                // Also cancel a pending model turn via the owner's failure callback. Resuming
                // after a phone call requires the user's explicit Start action.
                self.onFailure?()
            }
        }
    }

    func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        let microphone = await AVAudioApplication.requestRecordPermission()
        return speech && microphone
    }

    func listen(language: ConversationLanguage, glassesMicrophone: Bool) throws {
        stopListening()
        stopPlayback()
        var started = false
        defer { if !started { stopListening() } }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language.recognitionLocaleID)), recognizer.isAvailable else {
            throw SpeechFailure.unavailable
        }
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
        try audio.setActive(true)
        let selected: AVAudioSessionPortDescription
        if glassesMicrophone {
            // AVAudioSession identifies Bluetooth audio ports, not Meta hardware. Prefer the
            // user's current HFP route; never claim an arbitrary headset is the glasses.
            let inputs = audio.availableInputs?.filter { $0.portType == .bluetoothHFP } ?? []
            if let current = audio.currentRoute.inputs.first(where: { $0.portType == .bluetoothHFP }),
               let input = inputs.first(where: { $0.uid == current.uid }) {
                selected = input
            } else if inputs.count == 1, let input = inputs.first {
                selected = input
            } else {
                throw inputs.isEmpty ? SpeechFailure.bluetoothMicrophoneMissing : SpeechFailure.ambiguousBluetoothInput
            }
        } else {
            guard let input = audio.availableInputs?.first(where: { $0.portType == .builtInMic }) else { throw SpeechFailure.unavailable }
            selected = input
        }
        try audio.setPreferredInput(selected)
        guard let actual = audio.currentRoute.inputs.first(where: { $0.uid == selected.uid }) else { throw SpeechFailure.unavailable }
        selectedInputUID = actual.uid
        inputName = actual.portName
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        self.request = request
        transcript = ""
        committed = false
        let id = UUID()
        listenID = id
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechFailure.unavailable }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        tapInstalled = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            Task { @MainActor [weak self] in
                guard let self, self.listenID == id, self.isListening else { return }
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.transcript = text
                    self.silenceTask?.cancel()
                    self.silenceTask = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(1400))
                        guard !Task.isCancelled, let self, self.listenID == id else { return }
                        self.commit()
                    }
                    if final { self.commit() }
                } else if error != nil {
                    self.stopListening()
                    self.onFailure?()
                }
            }
        }
        isListening = true
        do { engine.prepare(); try engine.start() }
        catch { stopListening(); throw SpeechFailure.unavailable }
        started = true
    }

    func commit() {
        guard isListening, !committed else { return }
        let value = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        committed = true
        stopListening()
        onUtterance?(value)
    }

    func stopListening() {
        listenID = UUID()
        silenceTask?.cancel(); silenceTask = nil
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio(); task?.cancel()
        task = nil; request = nil; recognizer = nil; isListening = false
        selectedInputUID = nil; inputName = ""
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func verifyInputRoute() {
        guard isListening, let selectedInputUID else { return }
        guard let actual = AVAudioSession.sharedInstance().currentRoute.inputs.first(where: { $0.uid == selectedInputUID }) else {
            // A disconnected headset must not silently start sending the phone's microphone.
            stopListening()
            onFailure?()
            return
        }
        inputName = actual.portName
    }

    func speak(_ text: String, language: ConversationLanguage) throws {
        stopListening()
        stopPlayback()
        guard let voice = AVSpeechSynthesisVoice(language: language.speechLocaleID) else { throw SpeechFailure.voiceMissing }
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback, mode: .spokenAudio)
        try audio.setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        activeUtteranceID = ObjectIdentifier(utterance)
        synthesizer.speak(utterance)
    }

    private func stopPlayback() {
        activeUtteranceID = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    func stopAll() { stopListening(); stopPlayback() }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // Carry only a Sendable identity across actors, not the AVSpeechUtterance itself.
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.activeUtteranceID == id else { return }
            self.activeUtteranceID = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            self.onSpeechFinished?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            // Explicit Stop invalidates the identity first, so its delayed cancellation does
            // not become a new failure or terminate a newer utterance.
            guard let self, self.activeUtteranceID == id else { return }
            self.stopAll()
            self.onFailure?()
        }
    }

    enum SpeechFailure: Error { case unavailable, bluetoothMicrophoneMissing, ambiguousBluetoothInput, voiceMissing }
}
