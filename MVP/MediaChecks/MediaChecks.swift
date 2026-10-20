import Darwin
import Foundation
import OpenVisionCore

private struct CheckFailure: Error { let message: String }
@MainActor private func expect(_ value: Bool, _ message: String) throws {
    if !value { throw CheckFailure(message: message) }
}
@MainActor private func eventually(_ condition: () -> Bool) async throws {
    let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(2))
    while !condition() {
        guard clock.now < deadline else { throw CheckFailure(message: "Asynchronous fixture timed out") }
        try await Task.sleep(for: .milliseconds(1))
    }
}
private final class ClockFixture: @unchecked Sendable {
    private let lock = NSLock(); private var value: UInt64 = 0
    func now() -> UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: UInt64) { lock.lock(); self.value = value; lock.unlock() }
}
@MainActor private final class FakeMediaDriver: BluetoothMediaDriving {
    var hasClaim = false
    var hasBluetoothOutput = true
    var otherAudioPlaying = false
    var starts = 0, stops = 0, cues = 0
    var holdStart = false
    var startWaiter: CheckedContinuation<Void, Never>?
    var stopSucceeds = true
    var startFailure: BluetoothMediaFailure?
    var callbacks: [@MainActor @Sendable (BluetoothMediaDriverEvent) -> Void] = []
    var voiceChanges: [Bool] = []
    func start(events: @escaping @MainActor @Sendable (BluetoothMediaDriverEvent) -> Void) async throws {
        starts += 1
        if holdStart { await withCheckedContinuation { startWaiter = $0 } }
        hasClaim = true // Deliberately noncooperative: a late start recreates a handle after Stop.
        if let startFailure { throw startFailure }
        callbacks.append(events)
    }
    func setVoiceActive(_ value: Bool) async throws { voiceChanges.append(value) }
    func playDiagnosticCue() { cues += 1 }
    func stop() async -> Bool { stops += 1; if stopSucceeds { hasClaim = false }; return stopSucceeds }
    func emit(_ event: BluetoothMediaDriverEvent, index: Int? = nil) { callbacks[index ?? (callbacks.count - 1)](event) }
    func resumeStart() { startWaiter?.resume(); startWaiter = nil }
}
@MainActor private final class Counts {
    struct Receipt {
        let command: MediaVoiceCommand
        let nanoseconds: UInt64
        let foreground: Bool
    }
    var voice = 0, deactivated = 0
    var permits: [BluetoothMediaActivationPermit] = []
    var receipts: [Receipt] = []
}
@MainActor private func fixture() -> (BluetoothMediaTriggerService, FakeMediaDriver, Counts, ClockFixture) {
    let driver = FakeMediaDriver(), clock = ClockFixture(), counts = Counts()
    let service = BluetoothMediaTriggerService(driver: driver, nowNanoseconds: { clock.now() })
    service.onVoiceToggle = { permit in counts.voice += 1; counts.permits.append(permit) }
    service.onDeactivated = { counts.deactivated += 1 }
    service.onDiagnosticEvent = { command, nanoseconds, foreground in
        counts.receipts.append(.init(command: command, nanoseconds: nanoseconds, foreground: foreground))
    }
    return (service, driver, counts, clock)
}
@MainActor private func arm(_ service: BluetoothMediaTriggerService) async throws {
    service.setEnabled(true); await service.arm()
    try expect(service.isArmed, "Explicit arm failed")
}

@main struct MediaChecks {
    @MainActor static func main() async {
        let scenarios: [(String, @MainActor () async throws -> Void)] = [
            ("default off and enabling alone create no playback claim or cue", {
                let (service, driver, counts, _) = fixture()
                await service.arm(); service.setEnabled(true)
                try expect(!service.isArmed && service.action == .diagnosticsOnly && driver.starts == 0 && driver.cues == 0 && counts.voice == 0, "Default/enabling caused audio or activation")
            }),
            ("diagnostics count every raw command and play cues without voice activation", {
                let (service, driver, counts, _) = fixture(); try await arm(service)
                for command in MediaVoiceCommand.allCases { driver.emit(.command(command)) }
                try expect(service.eventCounts.values.reduce(0, +) == 5 && driver.cues == 6 && counts.voice == 0, "Diagnostic events escaped into voice or lost counters/cues")
                try expect(counts.receipts.map(\.command) == MediaVoiceCommand.allCases && counts.receipts.allSatisfy { $0.foreground && $0.nanoseconds == 0 }, "Synchronous diagnostic callback lost or mislabeled raw events")
                service.clearDiagnostics()
                try expect(service.eventCounts.isEmpty && service.lastCommand == nil, "Diagnostic reset retained event data")
                _ = await service.disarmAndWait()
            }),
            ("only explicitly selected next-track command issues a current voice permit", {
                let (service, driver, counts, _) = fixture(); service.setAction(.nextTrack); try await arm(service)
                for command in MediaVoiceCommand.allCases { driver.emit(.command(command)) }
                try expect(counts.voice == 1 && counts.permits[0].isValid && service.eventCounts.count == 5 && driver.cues == 1, "Mapping triggered other commands or mislabeled events")
                _ = await service.disarmAndWait()
            }),
            ("play/pause burst produces one toggle while retaining all raw diagnostics", {
                let (service, driver, counts, clock) = fixture(); service.setAction(.playPause); try await arm(service)
                driver.emit(.command(.play)); driver.emit(.command(.pause)); driver.emit(.command(.togglePlayPause))
                try expect(counts.voice == 1 && service.eventCounts.values.reduce(0, +) == 3, "One gesture burst became repeated toggles")
                clock.set(1_000_000_000); driver.emit(.command(.pause))
                try expect(counts.voice == 2, "A distinct later explicit gesture was lost")
                _ = await service.disarmAndWait()
            }),
            ("monotonic rollback cannot replay a matching command", {
                let (service, driver, counts, clock) = fixture(); service.setAction(.previousTrack); try await arm(service)
                clock.set(2_000_000_000); driver.emit(.command(.previousTrack))
                clock.set(1_000_000_000); driver.emit(.command(.previousTrack))
                try expect(counts.voice == 1, "Clock rollback replayed a toggle")
                _ = await service.disarmAndWait()
            }),
            ("disable immediately invalidates permits and old callbacks stay invalid after rearm", {
                let (service, driver, counts, clock) = fixture(); service.setAction(.nextTrack); try await arm(service)
                driver.emit(.command(.nextTrack)); let old = counts.permits[0]
                service.setEnabled(false)
                try expect(!old.isValid && !service.isArmed && counts.deactivated == 1, "Disable left queued activation valid")
                driver.emit(.command(.nextTrack), index: 0)
                try expect(counts.receipts.count == 1 && counts.voice == 1, "Disabled old callback produced a record or voice activation")
                _ = await service.disarmAndWait(); try await arm(service)
                clock.set(2_000_000_000); driver.emit(.command(.nextTrack), index: 0)
                try expect(counts.voice == 1 && counts.receipts.count == 1 && !old.isValid, "Old callback crossed into the new arm or produced a diagnostic record")
                driver.emit(.command(.nextTrack))
                try expect(counts.voice == 2 && counts.receipts.count == 2 && counts.permits[1].isValid, "Fresh arm did not work")
                _ = await service.disarmAndWait()
            }),
            ("changing mapping stops standby and invalidates already queued activation", {
                let (service, driver, counts, _) = fixture(); service.setAction(.nextTrack); try await arm(service)
                driver.emit(.command(.nextTrack)); let old = counts.permits[0]
                service.setAction(.playPause)
                try expect(!service.isArmed && !old.isValid, "Remapping silently reused an old activation")
                _ = await service.disarmAndWait()
            }),
            ("foreground explicit arm may survive lock for diagnostics but cannot arm from background", {
                let (service, driver, counts, clock) = fixture(); service.setEnabled(true); service.setForeground(false)
                await service.arm()
                try expect(driver.starts == 0 && service.failure == .notForeground, "Background created a fresh claim")
                service.setForeground(true); try await arm(service); service.setForeground(false)
                for (index, command) in MediaVoiceCommand.allCases.enumerated() {
                    clock.set(3_123_456_789 + UInt64(index)); driver.emit(.command(command))
                }
                try expect(service.isArmed && service.lastCommand == .previousTrack && counts.voice == 0, "Lock incorrectly started voice or discarded an explicit diagnostic standby")
                try expect(counts.receipts.map(\.command) == MediaVoiceCommand.allCases && counts.receipts.enumerated().allSatisfy { index, receipt in !receipt.foreground && receipt.nanoseconds == 3_123_456_789 + UInt64(index) }, "Background diagnostic callbacks did not preserve every exact receipt time and foreground=false")
                _ = await service.disarmAndWait(); service.setForeground(true)
                try expect(!service.isArmed && driver.starts == 1, "Foreground return automatically rearmed")
            }),
            ("no Bluetooth output or other audio blocks arm before driver calls", {
                for other in [false, true] {
                    let (service, driver, counts, _) = fixture(); service.setEnabled(true)
                    if other { driver.otherAudioPlaying = true } else { driver.hasBluetoothOutput = false }
                    await service.arm()
                    try expect(driver.starts == 0 && driver.cues == 0 && counts.voice == 0 && service.failure == (other ? .otherAudioPlaying : .bluetoothUnavailable), "Unavailable route stole playback")
                }
            }),
            ("photo or another audio owner blocks arm before driver calls", {
                let (service, driver, _, _) = fixture(); service.setEnabled(true); service.canArmSession = { false }
                await service.arm()
                try expect(driver.starts == 0 && service.failure == .busy, "Session owner guard was ignored")
            }),
            ("route loss invalidates standby and queued permits before voice dispatch", {
                let (service, driver, counts, clock) = fixture(); service.setAction(.playPause); try await arm(service)
                driver.emit(.command(.play)); let old = counts.permits[0]
                driver.hasBluetoothOutput = false; clock.set(2_000_000_000); driver.emit(.command(.play))
                try expect(!old.isValid && !service.isArmed && service.failure == .routeLost && counts.voice == 1, "Route loss delivered new voice activation")
                _ = await service.disarmAndWait()
            }),
            ("user media takes precedence and invalidates queued permits", {
                let (service, driver, counts, clock) = fixture(); service.setAction(.playPause); try await arm(service)
                driver.emit(.command(.play)); let old = counts.permits[0]
                driver.otherAudioPlaying = true; clock.set(2_000_000_000); driver.emit(.command(.pause))
                try expect(!old.isValid && !service.isArmed && service.failure == .otherAudioPlaying && counts.voice == 1, "User playback did not take precedence")
                _ = await service.disarmAndWait()
            }),
            ("interruption stops once even when root deactivation callback reenters disarm", {
                let (service, driver, counts, _) = fixture(); try await arm(service)
                service.onDeactivated = { counts.deactivated += 1; service.disarm() }
                driver.emit(.failed(.interrupted))
                try await eventually { !service.isCleaningUp }
                try expect(!service.isArmed && counts.deactivated == 1 && driver.stops == 1 && service.failure == .interrupted, "Interruption recursed, lost its error or duplicated cleanup")
            }),
            ("disarm barrier waits for noncooperative start and cleans its late claim", {
                let (service, driver, counts, _) = fixture(); service.setEnabled(true); driver.holdStart = true
                let starting = Task { await service.arm() }; try await eventually { driver.starts == 1 }
                let stopping = Task { await service.disarmAndWait(notify: false) }
                try await eventually { driver.stops == 1 }
                await service.arm(); try expect(driver.starts == 1 && !service.isReleased, "New arm overtook pending start")
                driver.resumeStart(); await starting.value
                let closed = await stopping.value
                try expect(closed && service.isReleased && driver.stops >= 2 && driver.cues == 0 && counts.voice == 0 && counts.deactivated == 0, "Late start escaped teardown barrier")
            }),
            ("failed teardown retains ownership and prevents a second driver start", {
                let (service, driver, _, _) = fixture(); try await arm(service); driver.stopSucceeds = false
                let released = await service.disarmAndWait()
                try expect(!released && !service.isReleased && service.failure == .teardown, "Failed cleanup falsely reported release")
                await service.arm(); try await eventually { !service.isCleaningUp }
                try expect(driver.starts == 1 && !service.isArmed, "Second playback claim opened before cleanup")
                driver.stopSucceeds = true; await service.arm()
                try expect(service.isArmed && driver.starts == 2, "Explicit retry could not recover")
                _ = await service.disarmAndWait()
            }),
            ("partial start failure cleans playback without issuing voice or cue", {
                let (service, driver, counts, _) = fixture(); driver.startFailure = .playbackFailed
                service.setEnabled(true); await service.arm(); try await eventually { !service.isCleaningUp }
                try expect(!service.isArmed && service.isReleased && driver.stops == 1 && driver.cues == 0 && counts.voice == 0, "Failed start leaked playback or triggered voice")
            }),
            ("voice handoff pauses and resumes only through explicit root calls", {
                let (service, driver, _, _) = fixture(); try await arm(service)
                await service.setVoiceActive(true); await service.setVoiceActive(false)
                try expect(driver.voiceChanges == [true, false] && !service.voiceActive, "Voice handoff was implicit or misordered")
                _ = await service.disarmAndWait()
            }),
            ("diagnostic recorder can disarm synchronously before any event cue or voice dispatch", {
                let (service, driver, counts, _) = fixture(); service.setAction(.nextTrack); try await arm(service)
                service.onDiagnosticEvent = { command, nanoseconds, foreground in
                    counts.receipts.append(.init(command: command, nanoseconds: nanoseconds, foreground: foreground))
                    service.disarm()
                }
                driver.emit(.command(.nextTrack))
                try expect(counts.receipts.count == 1 && driver.cues == 1 && counts.voice == 0 && !service.isArmed, "Recorder disarm was followed by a cue or voice activation")
                _ = await service.disarmAndWait()
            })
        ]
        do {
            for (name, test) in scenarios { try await test(); print("PASS: " + name) }
            print("PASS: \(scenarios.count) actual BluetoothMediaTriggerService/policy scenarios with injected playback effects. No Apple audio, microphone, camera, SDK, account, model or network calls. Hardware media delivery and locked-screen recording are NOT validated.")
        } catch {
            FileHandle.standardError.write(Data("FAIL: media checks: \(error)\n".utf8)); exit(1)
        }
    }
}
