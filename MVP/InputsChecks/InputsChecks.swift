import Darwin
import Foundation
import OpenVisionCore

private struct CheckFailure: Error { let message: String }
@MainActor private func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw CheckFailure(message: message) }
}
@MainActor private func settle(_ predicate: () -> Bool) async throws {
    let clock = ContinuousClock(), end = ContinuousClock().now.advanced(by: .seconds(2))
    while !predicate() {
        guard clock.now < end else { throw CheckFailure(message: "Local asynchronous fixture timed out") }
        try await Task.sleep(for: .milliseconds(1))
    }
}
private final class FixtureClock: @unchecked Sendable {
    private let lock = NSLock(); private var value: UInt64 = 0
    func now() -> UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: UInt64) { lock.lock(); self.value = value; lock.unlock() }
}
@MainActor private final class Counts {
    var voice = 0; var deactivated = 0
    var permits: [GlassesVoiceActivationPermit] = []
}
@MainActor private final class FakeInputDriver: GlassesInputDriving {
    var hasSession = false
    var starts = 0, stops = 0
    var startFailure: GlassesInputFailure?
    var stopSucceeds = true
    var suspendStart = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var streams: [AsyncStream<GlassesInputDriverEvent>.Continuation] = []
    func start() async throws -> AsyncStream<GlassesInputDriverEvent> {
        starts += 1
        if suspendStart { await withCheckedContinuation { startWaiter = $0 } }
        // Deliberately noncooperative: a late fake start recreates a handle after earlier stop.
        hasSession = true
        if let startFailure { throw startFailure }
        let result = AsyncStream<GlassesInputDriverEvent>.makeStream()
        streams.append(result.continuation)
        return result.stream
    }
    func resumeStart() { startWaiter?.resume(); startWaiter = nil }
    func stop() async -> Bool { stops += 1; if stopSucceeds { hasSession = false }; return stopSucceeds }
    func emit(_ event: GlassesInputDriverEvent, stream: Int? = nil) { streams[stream ?? (streams.count - 1)].yield(event) }
    func finish() { streams.last?.finish() }
}
@MainActor private func fixture(sdk: Bool = true) -> (GlassesInputService, FakeInputDriver, Counts, FixtureClock) {
    let driver = FakeInputDriver(), counts = Counts(), clock = FixtureClock()
    let service = GlassesInputService(driver: driver, sdkAvailable: sdk, nowNanoseconds: { clock.now() })
    service.onVoiceToggle = { permit in counts.voice += 1; counts.permits.append(permit) }
    service.onDeactivated = { counts.deactivated += 1 }
    return (service, driver, counts, clock)
}
private func select(_ timestamp: Int64, source: GlassesInputSource = .captouch) -> GlassesInputDriverEvent {
    .sample(.init(source: source, action: .select, timestampMilliseconds: timestamp))
}
@MainActor private func ready(_ service: GlassesInputService) async throws {
    service.setEnabled(true); await service.arm()
    try expect(service.isArmed && !service.isArming, "Explicit arm did not reach active state")
}

@main
struct InputsChecks {
    @MainActor static func main() async {
        var scenarios: [(String, @MainActor () async throws -> Void)] = []
        scenarios.append(("default off and enabling alone perform zero driver operations", {
            let (service, driver, counts, _) = fixture()
            try expect(!service.isEnabled && !service.isArmed, "Default is not off")
            await service.arm(); service.setEnabled(true)
            try expect(driver.starts == 0 && driver.stops == 0 && counts.voice == 0, "Off/enabling accessed hardware")
            service.setEnabled(false)
            try expect(counts.deactivated == 0 && driver.stops == 0, "Inactive disable touched driver")
        }))
        scenarios.append(("SDK configuration failure never accesses even an injected driver", {
            let (service, driver, counts, _) = fixture(sdk: false)
            service.setEnabled(true); await service.arm()
            try expect(service.failure == .sdkUnavailable && !service.isArmed && driver.starts == 0 && driver.stops == 0 && counts.voice == 0, "Unavailable SDK did not fail closed")
            try expect(service.statusText(language: .chinese).contains("SDK") && service.statusText(language: .english).contains("unavailable"), "Missing bilingual visible SDK error")
        }))
        scenarios.append(("photo or busy ownership denies arm before any driver call", {
            let (service, driver, counts, _) = fixture()
            service.setEnabled(true); service.canArmSession = { false }; await service.arm()
            try expect(service.failure == .busy && !service.isArmed && driver.starts == 0 && driver.stops == 0 && counts.voice == 0, "Blocked session ownership touched driver")
            try expect(service.statusText(language: .chinese).contains("结束") && service.statusText(language: .english).contains("Finish"), "Busy ownership is invisible")
        }))
        scenarios.append(("foreground active captouch Select invokes exactly one voice toggle", {
            let (service, driver, counts, _) = fixture(); try await ready(service)
            driver.emit(select(1)); try await settle { counts.voice == 1 }
            try expect(driver.starts == 1 && service.isArmed, "Voice input restarted hardware")
            try expect(await service.disarmAndWait() && counts.deactivated == 1 && driver.stops == 1, "Disarm not confirmed")
        }))
        scenarios.append(("duplicate, older and negative device timestamps cannot replay", {
            let (service, driver, counts, clock) = fixture(); try await ready(service)
            driver.emit(select(10)); try await settle { counts.voice == 1 }
            clock.set(2_000_000_000)
            driver.emit(select(10)); driver.emit(select(9)); driver.emit(select(-1)); driver.emit(select(11))
            try await settle { counts.voice == 2 }
            try expect(counts.voice == 2, "Old event replayed")
            _ = await service.disarmAndWait()
        }))
        scenarios.append(("phone monotonic burst debounce does not compare device and phone epochs", {
            let (service, driver, counts, clock) = fixture(); try await ready(service)
            driver.emit(select(9_000_000)); try await settle { counts.voice == 1 }
            for timestamp in 9_000_001...9_000_010 { driver.emit(select(Int64(timestamp))) }
            // Wait for the stream to process the burst before advancing the phone clock.
            for _ in 0..<40 { await Task.yield() }
            clock.set(1_000_000_000)
            driver.emit(select(9_000_010)); driver.emit(select(9_000_011))
            try await settle { counts.voice == 2 }
            try expect(counts.voice == 2, "Burst or replay became multiple toggles")
            _ = await service.disarmAndWait()
        }))
        scenarios.append(("capture, navigation, back, action, band and unknown sources never activate voice", {
            let (service, driver, counts, _) = fixture(); try await ready(service)
            for source in [GlassesInputSource.captureButton, .actionButton, .neuralBand, .unknown] { driver.emit(select(1, source: source)) }
            for action in [GlassesInputAction.capture, .navigation, .back, .button, .drag, .unknown] {
                driver.emit(.sample(.init(source: .captouch, action: action, timestampMilliseconds: 2)))
            }
            driver.emit(select(3)); try await settle { counts.voice == 1 }
            try expect(counts.voice == 1, "Unsupported event triggered voice")
            _ = await service.disarmAndWait()
        }))
        scenarios.append(("old stream cannot toggle a manually rearmed generation", {
            let (service, driver, counts, clock) = fixture(); try await ready(service)
            _ = await service.disarmAndWait(); await service.arm()
            try expect(service.isArmed && driver.starts == 2, "Manual rearm failed")
            clock.set(2_000_000_000); driver.emit(select(100), stream: 0); driver.emit(select(0), stream: 1)
            try await settle { counts.voice == 1 }
            try expect(counts.voice == 1, "Old epoch activated new session")
            _ = await service.disarmAndWait()
        }))
        scenarios.append(("queued voice permit is revoked synchronously by disarm and cannot survive rearm", {
            let (service, driver, counts, clock) = fixture(); try await ready(service)
            driver.emit(select(1)); try await settle { counts.permits.count == 1 }
            let queued = counts.permits[0]
            try expect(queued.isValid, "Live event did not carry its activation lease")
            service.disarm()
            try expect(!queued.isValid, "Queued event survived synchronous disarm")
            _ = await service.disarmAndWait(); await service.arm()
            try expect(service.isArmed && !queued.isValid, "New arm revived an old event lease")
            clock.set(2_000_000_000); driver.emit(select(1))
            try await settle { counts.permits.count == 2 }
            var lateActivations = 0
            if queued.isValid { lateActivations += 1 }
            if counts.permits[1].isValid { lateActivations += 1 }
            try expect(lateActivations == 1, "Delayed consumers did not distinguish activation generations")
            _ = await service.disarmAndWait()
        }))
        scenarios.append(("queued permit requires enabled foreground and retained active driver session", {
            let (service, driver, counts, _) = fixture(); try await ready(service)
            driver.emit(select(1)); try await settle { counts.permits.count == 1 }
            let permit = counts.permits[0]
            driver.hasSession = false
            try expect(!permit.isValid, "Lease survived loss of driver ownership")
            driver.hasSession = true; service.setForeground(false)
            try expect(!permit.isValid, "Lease survived leaving foreground")
            _ = await service.disarmAndWait(); service.setForeground(true); await service.arm()
            driver.emit(select(1)); try await settle { counts.permits.count == 2 }
            service.setEnabled(false)
            try expect(!counts.permits[1].isValid, "Lease survived disabling the feature")
            _ = await service.disarmAndWait()
        }))
        scenarios.append(("background immediately gates events, notifies stop and never automatically rearms", {
            let (service, driver, counts, _) = fixture(); try await ready(service)
            service.setForeground(false); driver.emit(select(1))
            try await settle { !service.isCleaningUp }
            service.setForeground(true)
            try expect(!service.isArmed && counts.voice == 0 && counts.deactivated == 1 && driver.starts == 1, "Background retained or automatically resumed voice")
        }))
        for (name, event, failure) in [
            ("paused", GlassesInputDriverEvent.paused, GlassesInputFailure.paused),
            ("stopped", .stopped, .ended),
            ("disconnected", .failed(.disconnected), .disconnected),
            ("permission denied", .failed(.permissionDenied), .permissionDenied),
            ("capability unavailable", .failed(.capabilityUnavailable), .capabilityUnavailable)
        ] {
            scenarios.append(("\(name) cleans session and stops voice without restart", {
                let (service, driver, counts, _) = fixture(); try await ready(service)
                driver.emit(select(1)); try await settle { counts.permits.count == 1 }
                driver.emit(event)
                try await settle { !service.isArmed && !service.isCleaningUp }
                try expect(service.failure == failure && counts.deactivated == 1 && driver.stops == 1 && driver.starts == 1, "Failure did not clean and notify")
                try expect(!counts.permits[0].isValid, "Session loss did not revoke an already queued voice action")
            }))
        }
        scenarios.append(("activation permission failure is visible and does not leave a handle", {
            let (service, driver, counts, _) = fixture(); driver.startFailure = .permissionDenied
            service.setEnabled(true); await service.arm(); try await settle { !service.isCleaningUp }
            try expect(!service.isArmed && !driver.hasSession && driver.stops == 1 && counts.deactivated == 1 && service.failure == .permissionDenied, "Start failure leaked session")
        }))
        scenarios.append(("disarm barrier waits for noncooperative late start and its cleanup", {
            let (service, driver, counts, _) = fixture(); driver.suspendStart = true; service.setEnabled(true)
            let arming = Task { await service.arm() }; try await settle { driver.starts == 1 }
            let barrier = Task { await service.disarmAndWait(notify: false) }
            try await settle { driver.stops == 1 }
            try expect(service.isArming && !service.isArmed, "Pending start lost ownership gate")
            await service.arm(); try expect(driver.starts == 1, "New arm overtook a pending old start")
            driver.resumeStart(); await arming.value
            let closed = await barrier.value
            try expect(closed && !driver.hasSession && !service.isArmed && driver.stops >= 2 && counts.voice == 0 && counts.deactivated == 0, "Barrier returned before late hardware was cleaned")
        }))
        scenarios.append(("task-cancelled arm cannot activate after driver returns", {
            let (service, driver, counts, _) = fixture(); driver.suspendStart = true; service.setEnabled(true)
            let task = Task { await service.arm() }; try await settle { driver.starts == 1 }
            task.cancel(); driver.resumeStart(); await task.value; try await settle { !service.isCleaningUp }
            try expect(!service.isArmed && !driver.hasSession && counts.deactivated == 1 && counts.voice == 0, "Cancelled arm activated")
        }))
        scenarios.append(("teardown failure blocks new hardware until explicit successful retry", {
            let (service, driver, _, _) = fixture(); try await ready(service); driver.stopSucceeds = false
            let closed = await service.disarmAndWait()
            try expect(!closed && service.failure == .teardown, "Unconfirmed teardown reported success")
            await service.arm(); try await settle { !service.isCleaningUp }
            try expect(driver.starts == 1 && !service.isArmed, "New session started before cleanup")
            driver.stopSucceeds = true; await service.arm()
            try expect(driver.starts == 2 && service.isArmed, "Manual cleanup retry could not recover")
            _ = await service.disarmAndWait()
        }))
        scenarios.append(("silent disarm is a confirmed camera handoff barrier without model.stop reentry", {
            let (service, driver, counts, _) = fixture(); try await ready(service)
            let closed = await service.disarmAndWait(notify: false)
            try expect(closed && !driver.hasSession && counts.deactivated == 0 && driver.stops == 1, "Silent barrier notified or retained session")
        }))
        scenarios.append(("deactivation callback can reenter disarm without recursion or duplicate cleanup", {
            let (service, driver, counts, _) = fixture(); try await ready(service)
            service.onDeactivated = { counts.deactivated += 1; service.disarm() }
            _ = await service.disarmAndWait()
            try expect(counts.deactivated == 1 && driver.stops == 1, "Stop callback recursed or duplicated teardown")
        }))
        scenarios.append(("model stop reentry cannot erase an approval error", {
            let (service, driver, counts, _) = fixture(); try await ready(service)
            service.onDeactivated = { counts.deactivated += 1; service.disarm() }
            driver.emit(.failed(.permissionDenied))
            try await settle { !service.isArmed && !service.isCleaningUp }
            try expect(service.failure == .permissionDenied && counts.deactivated == 1 && driver.stops == 1, "Reentrant model stop erased SDK failure")
        }))
        scenarios.append(("duplicate arm taps cannot create parallel sessions", {
            let (service, driver, _, _) = fixture(); driver.suspendStart = true; service.setEnabled(true)
            let first = Task { await service.arm() }; try await settle { driver.starts == 1 }
            await service.arm(); try expect(driver.starts == 1, "Duplicate arm started hardware")
            driver.resumeStart(); await first.value; _ = await service.disarmAndWait()
        }))
        scenarios.append(("unexpected event stream end deactivates instead of remaining armed", {
            let (service, driver, counts, _) = fixture(); try await ready(service); driver.finish()
            try await settle { !service.isArmed && !service.isCleaningUp }
            try expect(service.failure == .ended && counts.deactivated == 1 && driver.stops == 1, "Ended stream remained active")
        }))
        do {
            for (name, scenario) in scenarios { try await scenario(); print("PASS: " + name) }
            print("PASS: \(scenarios.count) production GlassesInputService/policy driver-injection scenarios. No SDK initialization, hardware, microphone, camera, account, model or network access. Mock pass does not validate actual glasses gesture delivery.")
        } catch { FileHandle.standardError.write(Data("FAIL: inputs checks: \(error)\n".utf8)); exit(1) }
    }
}
