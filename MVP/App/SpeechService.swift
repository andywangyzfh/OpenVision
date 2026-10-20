import Combine
import Foundation
import OpenVisionCore

/// Foreground turn controller. Default effects use real Apple APIs; tests inject only a driver.
@MainActor
final class SpeechService: ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var inputName = ""
    @Published private(set) var isListening = false
    var onUtterance: ((String) -> Void)?
    var onSpeechFinished: (() -> Void)?
    var onFailure: (() -> Void)?
    private let driver: any SpeechDriver
    private let silenceSleep: @Sendable () async throws -> Void
    private var silenceTask: Task<Void, Never>?
    private var listenID = UUID()
    private var committed = false
    private var activeUtteranceID: UUID?

    init(driver: (any SpeechDriver)? = nil,
         silenceSleep: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(1400)) }) {
        self.driver = driver ?? AppleSpeechDriver()
        self.silenceSleep = silenceSleep
        self.driver.onPlayback = { [weak self] id, event in self?.handlePlayback(id: id, event: event) }
        self.driver.onInputRoute = { [weak self] event in
            guard let self, self.isListening else { return }
            switch event {
            case .changed(let name): self.inputName = name
            case .lost: self.stopAll(); self.onFailure?()
            }
        }
        self.driver.onInterruption = { [weak self] in
            guard let self else { return }
            self.stopAll()
            // Notify during model processing too, so the owner can cancel that turn.
            self.onFailure?()
        }
    }

    func authorize() async -> Bool { await driver.authorize() }

    func listen(language: ConversationLanguage, glassesMicrophone: Bool) throws {
        stopListening(); stopPlayback()
        guard driver.recognitionAvailable(language: language) else { throw SpeechFailure.unavailable }
        transcript = ""; committed = false
        let id = UUID()
        listenID = id; isListening = true
        do {
            let name = try driver.startRecognition(language: language, bluetoothMicrophone: glassesMicrophone) { [weak self] event in
                self?.handleRecognition(event, id: id)
            }
            if listenID == id, isListening { inputName = name }
        } catch { stopListening(); throw error }
    }

    private func handleRecognition(_ event: SpeechRecognitionEvent, id: UUID) {
        guard listenID == id, isListening, !committed else { return }
        if let text = event.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            transcript = text
            silenceTask?.cancel()
            let sleep = silenceSleep
            silenceTask = Task { [weak self] in
                // Test clocks can deliberately deliver a stale timer after cancellation.
                guard !Task.isCancelled else { return }
                try? await sleep()
                guard !Task.isCancelled, let self, self.listenID == id else { return }
                self.commit()
            }
            if event.final { commit() }
        } else if event.failed || event.final {
            // An empty final has ended the platform recognizer too. Do not leave the UI
            // claiming to listen with a dead recognition task or submit an empty question.
            stopListening(); onFailure?()
        }
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
        isListening = false; inputName = ""
        driver.stopRecognition()
    }

    func speak(_ text: String, language: ConversationLanguage) throws {
        stopListening(); stopPlayback()
        guard driver.voiceAvailable(language: language) else { throw SpeechFailure.voiceMissing }
        let id = UUID()
        activeUtteranceID = id
        do { try driver.startPlayback(text: text, language: language, id: id) }
        catch { activeUtteranceID = nil; driver.deactivateAudio(); throw error }
    }

    private func handlePlayback(id: UUID, event: SpeechPlaybackEvent) {
        guard activeUtteranceID == id else { return }
        activeUtteranceID = nil
        driver.deactivateAudio()
        switch event {
        case .finished: onSpeechFinished?()
        case .cancelled: stopAll(); onFailure?()
        }
    }

    private func stopPlayback() { activeUtteranceID = nil; driver.stopPlayback() }
    func stopAll() { stopListening(); stopPlayback() }

    enum SpeechFailure: Error, Equatable { case unavailable, bluetoothMicrophoneMissing, ambiguousBluetoothInput, voiceMissing }
}
