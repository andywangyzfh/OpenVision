import Combine
import Foundation
import OpenVisionCore
import SubscriptionCore

// These fakes never open hardware, authentication or network connections. They deliberately
// ignore cancellation while suspended, so stale-result protection belongs to the production VM.
@MainActor
final class FlowWorld {
    static var current = FlowWorld()
    struct Request {
        let model: String
        let instructions: String
        let turns: [PlanTurn]
    }
    var catalog = [PlanModel(id: "fixture-plan", name: "Offline fixture model")]
    var modelLoads = 0
    var modelsError: PlanError?
    var invalidateBeforeModelsError = false
    var requests: [Request] = []
    var holdResponses = false
    var responseError: (any Error)?
    var answer = "你好，这是离线回答。"
    var pendingResponses: [CheckedContinuation<String, Error>] = []
    var completedResponses = 0

    func resolveResponses(_ answer: String = "迟到的离线回答") {
        let pending = pendingResponses
        pendingResponses.removeAll()
        pending.forEach { $0.resume(returning: answer) }
    }

    func resolveResponse(at index: Int, answer: String) {
        pendingResponses.remove(at: index).resume(returning: answer)
    }
}

@MainActor
final class ChatGPTPlanClient {
    private let world: FlowWorld
    private let account: ChatGPTAccountService
    init(account: ChatGPTAccountService) { world = .current; self.account = account }
    func models() async throws -> [PlanModel] {
        world.modelLoads += 1
        if let error = world.modelsError {
            if world.invalidateBeforeModelsError { account.invalidate() }
            throw error
        }
        return world.catalog
    }
    func respond(model: String, instructions: String, turns: [PlanTurn]) async throws -> String {
        world.requests.append(.init(model: model, instructions: instructions, turns: turns))
        if let error = world.responseError { throw error }
        let result: String
        if world.holdResponses {
            result = try await withCheckedThrowingContinuation { world.pendingResponses.append($0) }
        } else { result = world.answer }
        world.completedResponses += 1
        return result
    }
}

@MainActor
final class ChatGPTAccountService: ObservableObject {
    @Published private(set) var isSignedIn = false
    var signOutNotice: String?
    var cancelledSignIns = 0
    var signInCalls = 0
    var signInError: PlanError?
    var holdSignIn = false
    var pendingSignIns: [CheckedContinuation<Void, Never>] = []
    private var signInGeneration = 0
    var holdSignOut = false
    var holdCleanupRetry = false
    var pendingSignOut: CheckedContinuation<Void, Never>?
    var pendingCleanup: CheckedContinuation<Void, Never>?
    func restoreSignedIn() { isSignedIn = true }
    func invalidate() {
        signOutNotice = "订阅登录已失效，请重新登录 ChatGPT。 / Your plan sign-in expired or was revoked."
        isSignedIn = false
    }
    func restoreSavedSession() async throws { try await signIn() }
    func signIn() async throws {
        signInCalls += 1
        signInGeneration += 1
        let generation = signInGeneration
        if holdSignIn { await withCheckedContinuation { pendingSignIns.append($0) } }
        guard generation == signInGeneration else { throw CancellationError() }
        if let error = signInError { throw error }
        isSignedIn = true
    }
    func signOut() async {
        isSignedIn = false
        if holdSignOut { await withCheckedContinuation { pendingSignOut = $0 } }
    }
    func retryLocalCleanup() async {
        if holdCleanupRetry { await withCheckedContinuation { pendingCleanup = $0 } }
    }
    func finishSignOut() { let pending = pendingSignOut; pendingSignOut = nil; pending?.resume() }
    func finishCleanup() { let pending = pendingCleanup; pendingCleanup = nil; pending?.resume() }
    func finishSignIn(at index: Int) { pendingSignIns.remove(at: index).resume() }
    func cancelSignIn() { cancelledSignIns += 1; signInGeneration += 1 }
}

@MainActor
final class SpeechService: ObservableObject {
    enum SpeechFailure: Error { case unavailable, bluetoothMicrophoneMissing, ambiguousBluetoothInput, voiceMissing }
    struct Spoken { let text: String; let language: ConversationLanguage }
    struct Listening { let language: ConversationLanguage; let glassesMicrophone: Bool }
    var onUtterance: ((String) -> Void)?
    var onSpeechFinished: (() -> Void)?
    var onFailure: (() -> Void)?
    var holdAuthorization = false
    var authorizationAllowed = true
    var authorizationRequests = 0
    var pendingAuthorization: CheckedContinuation<Bool, Never>?
    var listening: [Listening] = []
    var spoken: [Spoken] = []
    var isListening = false
    var stopCalls = 0
    var listenError: SpeechFailure?
    var speakError: SpeechFailure?
    var listenAttempts = 0
    var speakAttempts = 0
    func authorize() async -> Bool {
        authorizationRequests += 1
        if holdAuthorization { return await withCheckedContinuation { pendingAuthorization = $0 } }
        return authorizationAllowed
    }
    func resolveAuthorization(_ allowed: Bool) {
        let pending = pendingAuthorization; pendingAuthorization = nil
        pending?.resume(returning: allowed)
    }
    func listen(language: ConversationLanguage, glassesMicrophone: Bool) throws {
        listenAttempts += 1
        if let error = listenError { throw error }
        listening.append(.init(language: language, glassesMicrophone: glassesMicrophone)); isListening = true
    }
    func speak(_ text: String, language: ConversationLanguage) throws {
        speakAttempts += 1
        if let error = speakError { throw error }
        spoken.append(.init(text: text, language: language)); isListening = false
    }
    func finishPlayback() { onSpeechFinished?() }
    func emitUtterance(_ value: String) { isListening = false; onUtterance?(value) }
    func emitFailure() { isListening = false; onFailure?() }
    func stopAll() { stopCalls += 1; isListening = false }
}

@MainActor
final class GlassesPhotoService: ObservableObject {
    enum PhotoFailure: Error { case sdkUnavailable, noGlasses, capture }
    let sdkAvailable: Bool
    var cameraActive = false
    var captures = 0
    var completedCaptures = 0
    var stopCalls = 0
    var photos: [Data] = []
    var failCapture = false
    var holdCapture = false
    var pendingCapture: CheckedContinuation<Data, Error>?
    var registrationURLs = 0
    init(monitoring: Bool, sdkAvailable: Bool = false) { self.sdkAvailable = sdkAvailable }
    func handleRegistrationURL(_ url: URL) async throws { registrationURLs += 1 }
    func captureJPEG() async throws -> Data {
        captures += 1; cameraActive = true
        defer { cameraActive = false }
        if failCapture { throw PhotoFailure.capture }
        let result: Data
        if holdCapture { result = try await withCheckedThrowingContinuation { pendingCapture = $0 } }
        else {
            guard !photos.isEmpty else { throw PhotoFailure.noGlasses }
            result = photos.removeFirst()
        }
        completedCaptures += 1
        return result
    }
    func resolveCapture(_ data: Data) {
        let pending = pendingCapture; pendingCapture = nil
        pending?.resume(returning: data)
    }
    func stop() { stopCalls += 1; cameraActive = false }
}
