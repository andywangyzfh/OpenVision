import Combine
import Dispatch
import Foundation
import OpenVisionCore

enum BluetoothMediaFailure: Error, Equatable, Sendable {
    case unavailable, busy, notForeground, bluetoothUnavailable, otherAudioPlaying
    case playbackFailed, interrupted, routeLost, teardown
}
enum BluetoothMediaDriverEvent: Sendable {
    case command(MediaVoiceCommand)
    case failed(BluetoothMediaFailure)
}

@MainActor
protocol BluetoothMediaDriving: AnyObject {
    var hasClaim: Bool { get }
    var hasBluetoothOutput: Bool { get }
    var otherAudioPlaying: Bool { get }
    func start(events: @escaping @MainActor @Sendable (BluetoothMediaDriverEvent) -> Void) async throws
    /// True pauses only the standby player. Voice owns/configures audio separately.
    func setVoiceActive(_ value: Bool) async throws
    func playDiagnosticCue()
    func stop() async -> Bool
}

@MainActor
final class BluetoothMediaActivationPermit {
    private let validate: @MainActor () -> Bool
    fileprivate init(_ validate: @escaping @MainActor () -> Bool) { self.validate = validate }
    var isValid: Bool { validate() }
}

/// Explicit experimental media standby. This file never requests microphone/camera access and
/// never submits text or a model request. Default diagnostics mode only counts incoming commands.
/// Public media events can also come from Control Center or another headset; no source is claimed.
@MainActor
final class BluetoothMediaTriggerService: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var isArmed = false
    @Published private(set) var isArming = false
    @Published private(set) var isCleaningUp = false
    @Published private(set) var voiceActive = false
    @Published private(set) var action: MediaVoiceAction = .diagnosticsOnly
    @Published private(set) var eventCounts: [MediaVoiceCommand: Int] = [:]
    @Published private(set) var lastCommand: MediaVoiceCommand?
    @Published private(set) var failure: BluetoothMediaFailure?
    var canArmSession: (@MainActor () -> Bool)?
    var onVoiceToggle: (@MainActor (BluetoothMediaActivationPermit) -> Void)?
    var onDeactivated: (@MainActor () -> Void)?
    var onDiagnosticEvent: (@MainActor (MediaVoiceCommand, UInt64, Bool) -> Void)?
    private let driver: any BluetoothMediaDriving
    private let now: @Sendable () -> UInt64
    private var foreground = true
    private var epoch: UInt64 = 0
    private var activationOwned = false
    private var policy = MediaVoiceTriggerPolicy()
    private var cleanup: Task<Bool, Never>?
    private var armWaiters: [CheckedContinuation<Void, Never>] = []

    init(driver: (any BluetoothMediaDriving)? = nil,
         nowNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.driver = driver ?? AppleBluetoothMediaDriver()
        now = nowNanoseconds
    }
    var canArm: Bool {
        isEnabled && foreground && !isArmed && !isArming && !isCleaningUp && canArmSession?() != false
    }
    var bluetoothRoutePresent: Bool { driver.hasBluetoothOutput }
    /// Even when unarmed, an in-flight start/cleanup must finish before another audio owner starts.
    var isReleased: Bool { !isArming && !isCleaningUp && !driver.hasClaim }

    func setEnabled(_ value: Bool) {
        isEnabled = value
        if !value { disarm() }
    }
    func setAction(_ value: MediaVoiceAction) {
        guard action != value else { return }
        disarm() // A remapping requires a fresh explicit Arm; old callbacks cannot acquire it.
        action = value
    }
    func setForeground(_ value: Bool) {
        foreground = value
        if !value, isArming { disarm() }
        // An already explicitly armed playback claim may survive a screen lock. No automatic arm.
    }
    func clearDiagnostics() { eventCounts = [:]; lastCommand = nil }

    func arm() async {
        guard foreground else { failure = .notForeground; return }
        guard canArm else { if canArmSession?() == false { failure = .busy }; return }
        guard driver.hasBluetoothOutput else { failure = .bluetoothUnavailable; return }
        guard !driver.otherAudioPlaying else { failure = .otherAudioPlaying; return }
        isArming = true; activationOwned = true; failure = nil
        epoch &+= 1; let owner = epoch
        defer {
            isArming = false
            let waiters = armWaiters; armWaiters = []
            waiters.forEach { $0.resume() }
        }
        do {
            if driver.hasClaim { guard await close().value else { throw BluetoothMediaFailure.teardown } }
            guard epoch == owner, isEnabled, foreground, canArmSession?() != false else {
                if epoch == owner { deactivate(.busy, notify: true) }
                return
            }
            try await driver.start { [weak self] event in self?.receive(event, owner: owner) }
            guard epoch == owner, isEnabled, foreground, canArmSession?() != false, !Task.isCancelled else {
                if epoch == owner { deactivate(.busy, notify: true) }
                else { _ = close() }
                return
            }
            guard driver.hasClaim, driver.hasBluetoothOutput, !driver.otherAudioPlaying else {
                throw BluetoothMediaFailure.playbackFailed
            }
            policy.reset(); isArmed = true
            driver.playDiagnosticCue()
        } catch {
            if epoch == owner { deactivate((error as? BluetoothMediaFailure) ?? .playbackFailed, notify: true) }
            else if driver.hasClaim { _ = close() }
        }
    }

    func disarm(notify: Bool = true) { deactivate(nil, notify: notify) }
    @discardableResult
    func disarmAndWait(notify: Bool = true) async -> Bool {
        disarm(notify: notify)
        if isArming { await withCheckedContinuation { armWaiters.append($0) } }
        if let cleanup { return await cleanup.value }
        return !driver.hasClaim
    }

    /// Root calls before starting speech and after the entire conversation has stopped, never
    /// for the gaps between listening, model work and TTS. It must not concurrently own Inputs.
    func setVoiceActive(_ value: Bool) async {
        guard isArmed else { return }
        let owner = epoch
        do {
            try await driver.setVoiceActive(value)
            guard owner == epoch, isArmed else { return }
            voiceActive = value
        } catch {
            guard owner == epoch else { return }
            deactivate((error as? BluetoothMediaFailure) ?? .playbackFailed, notify: true)
        }
    }

    private func receive(_ event: BluetoothMediaDriverEvent, owner: UInt64) {
        guard owner == epoch, isEnabled else { return }
        switch event {
        case .failed(let reason): deactivate(reason, notify: true)
        case .command(let command):
            guard isArmed, driver.hasClaim else { return }
            guard driver.hasBluetoothOutput else { deactivate(.routeLost, notify: true); return }
            guard !driver.otherAudioPlaying else { deactivate(.otherAudioPlaying, notify: true); return }
            eventCounts[command, default: 0] += 1; lastCommand = command
            let receivedAt = now()
            onDiagnosticEvent?(command, receivedAt, foreground)
            guard owner == epoch, isArmed else { return }
            if action == .diagnosticsOnly { driver.playDiagnosticCue() }
            guard policy.accepts(command, action: action, atNanoseconds: receivedAt) else { return }
            let permit = BluetoothMediaActivationPermit { [weak self] in
                guard let self else { return false }
                return epoch == owner && isEnabled && isArmed && !isCleaningUp
                    && action != .diagnosticsOnly && driver.hasClaim && driver.hasBluetoothOutput
                    && !driver.otherAudioPlaying
            }
            if permit.isValid { onVoiceToggle?(permit) }
        }
    }
    private func deactivate(_ reason: BluetoothMediaFailure?, notify: Bool) {
        let owned = activationOwned
        activationOwned = false
        epoch &+= 1; isArmed = false; voiceActive = false; policy.reset()
        if reason != nil || owned { failure = reason }
        if owned || driver.hasClaim || cleanup != nil { _ = close() }
        if owned, notify { onDeactivated?() }
    }
    private func close() -> Task<Bool, Never> {
        if let cleanup { return cleanup }
        isCleaningUp = true
        let task = Task { @MainActor [self] in
            let released = await driver.stop()
            isCleaningUp = false; cleanup = nil
            if !released { failure = .teardown }
            return released
        }
        cleanup = task
        return task
    }
}
