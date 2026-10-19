import Foundation
import OpenVisionCore

#if canImport(MWDATCore) && canImport(MWDATInputs)
import MWDATCore
import MWDATInputs

/// Inputs-only boundary. Deliberately imports no Camera module, requests no camera permission,
/// and attaches no camera capability. Only an explicit foreground Arm reaches Wearables.shared.
@MainActor
final class DATInputDriver: GlassesInputDriving {
    struct Timing {
        var sessionStart: TimeInterval = 15
        var activation: TimeInterval = 15
        var teardown: TimeInterval = 5
        var poll: TimeInterval = 0.05
    }
    private let sdkAvailable: Bool
    private let timing: Timing
    private var session: DeviceSession?
    private var inputs: Inputs?
    private var tokens: [any AnyListenerToken] = []
    private var stateTask: Task<Void, Never>?
    private var errorTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var continuation: AsyncStream<GlassesInputDriverEvent>.Continuation?
    private var generation: UInt64 = 0
    private var lastFailure: GlassesInputFailure?
    private var active = false
    var hasSession: Bool { session != nil }
    init(sdkAvailable: Bool = false, timing: Timing = Timing()) { self.sdkAvailable = sdkAvailable; self.timing = timing }

    func start() async throws -> AsyncStream<GlassesInputDriverEvent> {
        guard sdkAvailable else { throw GlassesInputFailure.sdkUnavailable }
        guard session == nil else { throw GlassesInputFailure.teardown }
        try Task.checkCancellation()
        let wearables = Wearables.shared
        guard wearables.registrationState == .registered else { throw GlassesInputFailure.registrationRequired }
        guard !wearables.devices.isEmpty else { throw GlassesInputFailure.noDevice }
        guard wearables.devices.count == 1, let device = wearables.devices.first else { throw GlassesInputFailure.ambiguousDevices }
        generation &+= 1; let owner = generation
        lastFailure = nil; active = false
        let output = AsyncStream<GlassesInputDriverEvent>.makeStream(bufferingPolicy: .bufferingNewest(32))
        continuation = output.continuation
        let created = try wearables.createSession(deviceSelector: SpecificDeviceSelector(device: device))
        session = created
        stateTask = Task { @MainActor [weak self] in
            for await state in created.stateStream() {
                guard let self, generation == owner else { return }
                switch state {
                case .paused: fail(.paused, event: .paused)
                case .stopping, .stopped: fail(.ended, event: .stopped)
                default: break
                }
            }
        }
        errorTask = Task { @MainActor [weak self] in
            for await _ in created.errorStream() {
                guard let self, generation == owner else { return }
                fail(.activationFailed)
            }
        }
        try created.start()
        try await wait(owner: owner, timeout: timing.sessionStart) { created.state == .started }
        try check(owner)
        // [] is an SDK wildcard for ALL sources. Keep the source set explicit and nonempty.
        let configuration = InputsConfiguration(sources: [.captouch], consumeBack: false)
        guard let attached = try created.addInputs(configuration: configuration) else { throw GlassesInputFailure.capabilityUnavailable }
        inputs = attached
        tokens.append(attached.statePublisher.listen { [weak self] state in
            Task { @MainActor in
                guard let self, self.generation == owner else { return }
                if state == .active { self.active = true }
                else if self.active { self.fail(.disconnected) }
            }
        })
        tokens.append(attached.errorPublisher.listen { [weak self] error in
            Task { @MainActor in
                guard let self, self.generation == owner else { return }
                switch error {
                case .permissionDenied: self.fail(.permissionDenied)
                case .capabilityUnavailable: self.fail(.capabilityUnavailable)
                case .deviceDisconnected, .connectionClosed: self.fail(.disconnected)
                case .activationTimeout: self.fail(.timeout)
                default: self.fail(.activationFailed)
                }
            }
        })
        inputTask = Task { @MainActor [weak self] in
            for await event in attached.events {
                guard let self, generation == owner else { return }
                guard created.state == .started, attached.state == .active, lastFailure == nil else { continue }
                continuation?.yield(.sample(Self.sample(event)))
            }
            guard let self, generation == owner, lastFailure == nil else { return }
            fail(.ended)
        }
        try await wait(owner: owner, timeout: timing.activation) { attached.state == .active }
        try check(owner)
        guard created.state == .started, attached.state == .active else { throw GlassesInputFailure.activationFailed }
        active = true
        return output.stream
    }
    private func check(_ owner: UInt64) throws {
        try Task.checkCancellation()
        guard generation == owner else { throw CancellationError() }
        if let lastFailure { throw lastFailure }
    }
    private func wait(owner: UInt64, timeout: TimeInterval, until predicate: () -> Bool) async throws {
        let clock = ContinuousClock(), end = ContinuousClock().now.advanced(by: .seconds(timeout))
        while true {
            try check(owner)
            if predicate() { return }
            guard clock.now < end else { throw GlassesInputFailure.timeout }
            try await Task.sleep(for: .seconds(max(0.001, timing.poll)))
        }
    }
    private func fail(_ reason: GlassesInputFailure, event: GlassesInputDriverEvent? = nil) {
        guard lastFailure == nil else { return }
        lastFailure = reason; active = false
        continuation?.yield(event ?? .failed(reason)); continuation?.finish()
    }
    func stop() async -> Bool {
        guard sdkAvailable else { return session == nil }
        generation &+= 1; active = false
        stateTask?.cancel(); stateTask = nil; errorTask?.cancel(); errorTask = nil
        inputTask?.cancel(); inputTask = nil
        continuation?.finish(); continuation = nil
        // Listener release cancels observations. Generation checks also reject queued callbacks.
        tokens.removeAll()
        guard let stopping = session else { inputs = nil; return true }
        // Parent stop cascades to attached capabilities even if removeInputs reports an error.
        do { try stopping.removeInputs() } catch {}
        stopping.stop()
        let clock = ContinuousClock(), end = ContinuousClock().now.advanced(by: .seconds(timing.teardown))
        while stopping.state != .stopped, clock.now < end {
            do { try await Task.sleep(for: .seconds(max(0.001, timing.poll))) }
            catch { return false }
        }
        guard stopping.state == .stopped else { return false }
        inputs = nil; session = nil; lastFailure = nil
        return true
    }
    private static func sample(_ event: InputEvent) -> GlassesInputSample {
        let source: GlassesInputSource
        switch event.source {
        case .captouch: source = .captouch
        case .captureButton: source = .captureButton
        case .actionButton: source = .actionButton
        case .neuralBand, .neuralBandDrag: source = .neuralBand
        case .unknown: source = .unknown
        }
        let action: GlassesInputAction
        switch event {
        case .select: action = .select
        case .nav: action = .navigation
        case .back: action = .back
        case .capture: action = .capture
        case .button: action = .button
        case .drag: action = .drag
        @unknown default: action = .unknown
        }
        return .init(source: source, action: action, timestampMilliseconds: event.timestampMs)
    }
}
#else
@MainActor
final class DATInputDriver: GlassesInputDriving {
    var hasSession: Bool { false }
    init(sdkAvailable: Bool = false) {}
    func start() async throws -> AsyncStream<GlassesInputDriverEvent> { throw GlassesInputFailure.sdkUnavailable }
    func stop() async -> Bool { true }
}
#endif
