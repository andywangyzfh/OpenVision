#if DEBUG
import Foundation
import OpenVisionCore
import SubscriptionCore
import SwiftUI

private struct QuestionFocusObserverKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable (Bool) -> Void)? = nil
}

extension EnvironmentValues {
    var questionFocusObserver: (@MainActor @Sendable (Bool) -> Void)? {
        get { self[QuestionFocusObserverKey.self] }
        set { self[QuestionFocusObserverKey.self] = newValue }
    }
}

/// Explicit local-only launch mode. No Apple microphone/synthesizer, SDK, account or model I/O.
/// Completion is injected at the SpeechDriver boundary, never into VM state or its callbacks.
@MainActor
final class StatusUITestFixture: ObservableObject, SpeechDriver {
    var onPlayback: ((UUID, SpeechPlaybackEvent) -> Void)?
    var onInputRoute: ((SpeechInputRouteEvent) -> Void)?
    var onInterruption: (() -> Void)?
    @Published private(set) var requests = 0
    @Published private(set) var playbacks = 0
    @Published private(set) var listens = 0
    @Published private(set) var questionFocused = false
    @Published private(set) var focusChanges = 0
    @Published private(set) var lastFocusUptime: UInt64 = 0
    private var playbackIDs: [UUID] = []
    private var receiveRecognition: (@MainActor (SpeechRecognitionEvent) -> Void)?
    private var pendingAnswer: CheckedContinuation<String, Error>?
    private var pendingText = ""
    private let holdAnswer: Bool
    private let missingVoice: Bool

    init(arguments: [String]) {
        holdAnswer = arguments.contains("--mvp-status-hold-model")
        missingVoice = arguments.contains("--mvp-status-missing-voice")
    }

    func recordQuestionFocus(_ focused: Bool) {
        questionFocused = focused
        focusChanges += 1
        lastFocusUptime = DispatchTime.now().uptimeNanoseconds
    }

    func modelEffect() -> ConversationViewModel.LocalModelEffect {
        .init(model: .init(id: "local-platform-fixture", name: "Local platform fixture (no network)")) { [self] _, instructions, _ in
            requests += 1
            let answer = instructions.contains("简体中文") ? "1加2等于3。" : "One plus two equals three."
            if holdAnswer {
                pendingText = answer
                return try await withCheckedThrowingContinuation { pendingAnswer = $0 }
            }
            return answer
        }
    }

    func finishLatestPlayback() {
        guard let id = playbackIDs.last else { return }
        onPlayback?(id, .finished)
    }
    func finishPreviousPlayback() {
        guard playbackIDs.count >= 2 else { return }
        onPlayback?(playbackIDs[playbackIDs.count - 2], .finished)
    }
    func resolveModel() {
        let pending = pendingAnswer; pendingAnswer = nil
        pending?.resume(returning: pendingText)
    }
    func emitQuestion() { receiveRecognition?(.init(text: "1加2等于多少", final: true)) }
    func authorize() async -> Bool { true }
    func recognitionAvailable(language: ConversationLanguage) -> Bool { true }
    func startRecognition(language: ConversationLanguage, bluetoothMicrophone: Bool,
                          receive: @escaping @MainActor (SpeechRecognitionEvent) -> Void) throws -> String {
        listens += 1; receiveRecognition = receive
        return "Injected local input (no microphone)"
    }
    func stopRecognition() { receiveRecognition = nil }
    func voiceAvailable(language: ConversationLanguage) -> Bool { !missingVoice }
    func startPlayback(text: String, language: ConversationLanguage, id: UUID) throws {
        playbacks += 1; playbackIDs.append(id)
    }
    // Retain IDs deliberately: the UI test can deliver a stale platform callback after Stop.
    func stopPlayback() {}
    func deactivateAudio() {}
}

struct StatusUITestControls: View {
    @ObservedObject var fixture: StatusUITestFixture
    @ObservedObject var model: ConversationViewModel
    var body: some View {
        VStack(spacing: 3) {
            Text("PLATFORM FIXTURE · NO NETWORK · preview=false").font(.caption2)
                .accessibilityIdentifier("fixture.platform.banner")
            Text("stage=\(String(describing: model.stage));busy=\(model.busy);canSend=\(model.canSend);preview=\(model.debugPreview);requests=\(fixture.requests);playbacks=\(fixture.playbacks);listens=\(fixture.listens)")
                .font(.caption2).accessibilityIdentifier("fixture.platform.state")
                .accessibilityValue("focus=\(fixture.questionFocused);focusChanges=\(fixture.focusChanges);lastFocusUptime=\(fixture.lastFocusUptime)")
            HStack {
                Button("Finish") { fixture.finishLatestPlayback() }.accessibilityIdentifier("fixture.platform.finish")
                Button("Old") { fixture.finishPreviousPlayback() }.accessibilityIdentifier("fixture.platform.old-finish")
                Button("Answer") { fixture.resolveModel() }.accessibilityIdentifier("fixture.platform.answer")
                Button("Say") { fixture.emitQuestion() }.accessibilityIdentifier("fixture.platform.say")
            }.buttonStyle(.bordered).font(.caption)
        }.padding(4).background(Color.yellow.opacity(0.15))
    }
}
#endif
