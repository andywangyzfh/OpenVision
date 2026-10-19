import Combine
import Dispatch
import Foundation
import OpenVisionCore

@MainActor
protocol GlassesInputDriving: AnyObject {
    var hasSession: Bool { get }
    func start() async throws -> AsyncStream<GlassesInputDriverEvent>
    /// True only after Inputs is detached and the parent session is stopped/released.
    func stop() async -> Bool
}

enum GlassesInputDriverEvent: Sendable {
    case sample(GlassesInputSample)
    case paused
    case stopped
    case failed(GlassesInputFailure)
}
enum GlassesInputFailure: Error, Equatable, Sendable {
    case sdkUnavailable, registrationRequired, noDevice, ambiguousDevices, permissionDenied, capabilityUnavailable
    case activationFailed, timeout, disconnected, paused, ended, teardown, busy
}

/// A queued voice action must retain this exact activation lease and recheck it
/// at every asynchronous boundary. A later manual rearm cannot revive an old lease.
@MainActor
final class GlassesVoiceActivationPermit {
    private let validate: @MainActor () -> Bool
    fileprivate init(validate: @escaping @MainActor () -> Bool) { self.validate = validate }
    var isValid: Bool { validate() }
}

/// Camera-free, opt-in physical-input coordination. Constructing it does not access the SDK.
@MainActor
final class GlassesInputService: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var isArmed = false
    @Published private(set) var isArming = false
    @Published private(set) var isCleaningUp = false
    @Published private(set) var failure: GlassesInputFailure?
    var onVoiceToggle: (@MainActor (GlassesVoiceActivationPermit) -> Void)?
    var onDeactivated: (@MainActor () -> Void)?
    /// Root coordinator prevents a second DAT session while a photo/voice operation owns it.
    var canArmSession: (@MainActor () -> Bool)?
    private let driver: any GlassesInputDriving
    private let sdkAvailable: Bool
    private let nowNanoseconds: @Sendable () -> UInt64
    private var foreground = true
    private var epoch: UInt64 = 0
    private var activationOwned = false
    private var policy = GlassesVoiceInputPolicy()
    private var eventTask: Task<Void, Never>?
    private var cleanupTask: Task<Bool, Never>?
    private var armWaiters: [CheckedContinuation<Void, Never>] = []

    init(driver: (any GlassesInputDriving)? = nil, sdkAvailable: Bool = false,
         nowNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.driver = driver ?? DATInputDriver(sdkAvailable: sdkAvailable)
        self.sdkAvailable = sdkAvailable
        self.nowNanoseconds = nowNanoseconds
    }
    var canArm: Bool { isEnabled && foreground && !isArming && !isArmed && !isCleaningUp && canArmSession?() != false }
    func setEnabled(_ value: Bool) {
        isEnabled = value
        if !value { disarm() }
        // Enabling never starts a session. A separate explicit Arm action is required.
    }
    func setForeground(_ value: Bool) {
        foreground = value
        if !value { disarm() }
        // Returning to foreground never rearms a session or opens the microphone.
    }
    func arm() async {
        guard canArmSession?() != false else { failure = .busy; return }
        guard canArm else { return }
        guard sdkAvailable else { failure = .sdkUnavailable; return }
        isArming = true; activationOwned = true; failure = nil
        epoch &+= 1; let owner = epoch
        defer {
            isArming = false
            let waiters = armWaiters; armWaiters = []
            waiters.forEach { $0.resume() }
        }
        do {
            if let cleanupTask { guard await cleanupTask.value else { throw GlassesInputFailure.teardown } }
            try ensureCurrent(owner)
            if driver.hasSession { guard await startCleanup().value else { throw GlassesInputFailure.teardown } }
            try ensureCurrent(owner)
            let events = try await driver.start()
            try ensureCurrent(owner)
            policy.arm(epoch: owner); isArmed = true
            eventTask = Task { @MainActor [weak self] in
                for await event in events {
                    guard let self, epoch == owner, isArmed, foreground, isEnabled else { return }
                    handle(event, owner: owner)
                }
                guard let self, epoch == owner, isArmed else { return }
                deactivate(reason: .ended, notify: true)
            }
        } catch {
            if epoch == owner {
                deactivate(reason: (error as? GlassesInputFailure) ?? (error is CancellationError ? nil : .activationFailed), notify: true)
            } else if driver.hasSession {
                // No new arm can overtake isArming. Clean a noncooperative late start rather
                // than letting its returned stream reactivate this invalidated operation.
                _ = startCleanup()
            }
        }
    }
    func disarm(notify: Bool = true) { deactivate(reason: nil, notify: notify) }
    @discardableResult func disarmAndWait(notify: Bool = true) async -> Bool {
        disarm(notify: notify)
        if isArming { await withCheckedContinuation { armWaiters.append($0) } }
        if let cleanupTask { return await cleanupTask.value }
        return !driver.hasSession
    }
    private func ensureCurrent(_ owner: UInt64) throws {
        try Task.checkCancellation()
        guard epoch == owner, activationOwned, foreground, isEnabled else { throw CancellationError() }
        guard canArmSession?() != false else { throw GlassesInputFailure.busy }
    }
    private func handle(_ event: GlassesInputDriverEvent, owner: UInt64) {
        switch event {
        case .sample(let sample):
            guard policy.shouldToggle(sample, epoch: owner, receivedAtNanoseconds: nowNanoseconds()) else { return }
            let permit = GlassesVoiceActivationPermit { [weak self] in
                guard let self else { return false }
                return epoch == owner && activationOwned && isEnabled && foreground && isArmed
                    && !isArming && !isCleaningUp && driver.hasSession
            }
            guard permit.isValid else { return }
            onVoiceToggle?(permit)
        case .paused: deactivate(reason: .paused, notify: true)
        case .stopped: deactivate(reason: .ended, notify: true)
        case .failed(let reason): deactivate(reason: reason, notify: true)
        }
    }
    private func deactivate(reason: GlassesInputFailure?, notify: Bool) {
        let shouldNotify = activationOwned
        activationOwned = false; epoch &+= 1; policy.invalidate(); isArmed = false
        eventTask?.cancel(); eventTask = nil
        // A model.stop -> disarm reentry must not erase the SDK failure just shown to users.
        if reason != nil || shouldNotify { failure = reason }
        if sdkAvailable, shouldNotify || driver.hasSession || cleanupTask != nil { _ = startCleanup() }
        // Clear ownership before calling out: a model.stop -> disarm reentry is harmless.
        if notify && shouldNotify { onDeactivated?() }
    }
    private func startCleanup() -> Task<Bool, Never> {
        if let cleanupTask { return cleanupTask }
        isCleaningUp = true
        let task = Task { @MainActor [self] in
            let closed = await driver.stop()
            isCleaningUp = false; cleanupTask = nil
            if !closed { failure = .teardown }
            return closed
        }
        cleanupTask = task
        return task
    }
    func statusText(language: ConversationLanguage) -> String {
        let chinese = language == .chinese
        if isEnabled, !isArmed, canArmSession?() == false {
            return chinese ? "请先结束当前语音、待确认照片或拍照清理，再开启双击待命。" : "Finish the current voice, pending photo or photo cleanup before enabling gesture standby."
        }
        if let failure {
            switch failure {
            case .sdkUnavailable: return chinese ? "眼镜 SDK 未就绪，双击待命未开启。" : "Glasses SDK unavailable; gesture standby is off."
            case .permissionDenied: return chinese ? "Meta 尚未批准此 App 的触控功能。请检查开发者中心后重试。" : "Meta has not approved gesture input for this app. Check Developer Center, then retry."
            case .capabilityUnavailable: return chinese ? "此设备或配置暂不支持双击待命，请检查 Meta 连接及功能授权。" : "Gesture standby is unavailable on this device or configuration. Check Meta connection and feature access."
            case .registrationRequired, .noDevice: return chinese ? "请先在 App 中连接并注册眼镜，再手动开启双击待命。" : "Connect and register glasses in the app, then enable double-tap standby."
            case .ambiguousDevices: return chinese ? "检测到多副眼镜，暂不选择设备；请仅连接目标眼镜后重试。" : "Multiple glasses detected; connect only the intended pair, then retry."
            case .paused: return chinese ? "眼镜连接已暂停，语音已停止。请手动重新开启双击待命。" : "Glasses connection paused; voice stopped. Enable double-tap standby again manually."
            case .teardown: return chinese ? "眼镜连接尚未确认结束，暂不能再次开启手势或拍照。" : "The glasses connection has not finished closing; gestures and a new photo are blocked."
            case .busy: return chinese ? "请先结束当前操作，再开启双击待命。" : "Finish the current operation before enabling gesture standby."
            default: return chinese ? "手势待命已停止。检查眼镜连接或 Meta 功能授权后手动重试。" : "Gesture standby stopped. Check glasses connection or Meta feature access, then retry manually."
            }
        }
        if isCleaningUp { return chinese ? "正在停止眼镜手势待命…" : "Stopping glasses gesture standby…" }
        if isArming { return chinese ? "正在开启双击待命…" : "Enabling double-tap standby…" }
        if isArmed { return chinese ? "双击待命已开启：双击镜腿开始语音，再次双击停止。本 App 的语音操作不会开启相机。" : "Double-tap standby is on: double-tap the temple to start voice, then double-tap again to stop. This app's voice controls do not open the camera."
        }
        return chinese ? "双击待命默认关闭。打开开关后手动开启待命；App 离开前台后需重新开启。" : "Double-tap standby is off by default. Turn on the switch and enable standby manually; enable it again after the app leaves the foreground."
    }
}
