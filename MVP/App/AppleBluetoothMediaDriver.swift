import Foundation
import OpenVisionCore

#if os(iOS)
import AVFAudio
import MediaPlayer

/// Uses Apple's media-remote API only. It cannot identify the sender as Ray-Ban glasses.
/// Arm starts a zero-volume output loop; diagnostic commands play a short audible output cue.
/// There is no audio-input node, microphone authorization, camera framework or DAT capability.
@MainActor
final class AppleBluetoothMediaDriver: BluetoothMediaDriving {
    private static let title = "OpenVision Media Event Test"
    private nonisolated static let audioQueue = DispatchQueue(label: "OpenVision.media-standby.audio")
    private var generation: UInt64 = 0
    private var standby: AVAudioPlayer?
    private var cue: AVAudioPlayer?
    private var targets: [(MPRemoteCommand, Any)] = []
    private var observers: [NSObjectProtocol] = []
    private var events: (@MainActor @Sendable (BluetoothMediaDriverEvent) -> Void)?
    private var ownsPlaybackSession = false
    private var configuringPlayback = false
    private var voiceActive = false
    var hasClaim: Bool { !targets.isEmpty || standby != nil || ownsPlaybackSession || configuringPlayback }
    var otherAudioPlaying: Bool { AVAudioSession.sharedInstance().isOtherAudioPlaying }
    var hasBluetoothOutput: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            $0.portType == .bluetoothA2DP || $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE
        }
    }

    func start(events: @escaping @MainActor @Sendable (BluetoothMediaDriverEvent) -> Void) async throws {
        guard !hasClaim else { throw BluetoothMediaFailure.busy }
        guard hasBluetoothOutput else { throw BluetoothMediaFailure.bluetoothUnavailable }
        guard !otherAudioPlaying else { throw BluetoothMediaFailure.otherAudioPlaying }
        generation &+= 1; let owner = generation
        self.events = events; voiceActive = false; configuringPlayback = true
        try await Self.configurePlayback()
        guard generation == owner, !Task.isCancelled else { throw CancellationError() }
        configuringPlayback = false; ownsPlaybackSession = true
        guard hasBluetoothOutput, !otherAudioPlaying else { throw BluetoothMediaFailure.bluetoothUnavailable }
        let player = try AVAudioPlayer(data: Self.wav(tone: false))
        player.numberOfLoops = -1; player.volume = 0
        standby = player
        guard player.prepareToPlay(), player.play() else { throw BluetoothMediaFailure.playbackFailed }
        let center = MPRemoteCommandCenter.shared()
        for (command, value) in [(center.playCommand, MediaVoiceCommand.play),
                                 (center.pauseCommand, .pause),
                                 (center.togglePlayPauseCommand, .togglePlayPause),
                                 (center.nextTrackCommand, .nextTrack),
                                 (center.previousTrackCommand, .previousTrack)] {
            command.isEnabled = true
            let target = command.addTarget { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == owner else { return }
                    self.events?(.command(value))
                }
                return .success
            }
            targets.append((command, target))
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: Self.title,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0
        ]
        let notifications = NotificationCenter.default
        observers.append(notifications.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in
                guard let self, self.generation == owner else { return }
                self.events?(.failed(.interrupted))
            }
        })
        for name in [AVAudioSession.routeChangeNotification, AVAudioSession.silenceSecondaryAudioHintNotification] {
            observers.append(notifications.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == owner else { return }
                    if !self.hasBluetoothOutput { self.events?(.failed(.routeLost)) }
                    else if self.otherAudioPlaying { self.events?(.failed(.otherAudioPlaying)) }
                }
            })
        }
    }

    func playDiagnosticCue() {
        guard !voiceActive, hasBluetoothOutput else { return }
        do {
            cue?.stop()
            let tone = try AVAudioPlayer(data: Self.wav(tone: true))
            tone.volume = 0.35; cue = tone
            if !tone.play() { events?(.failed(.playbackFailed)) }
        } catch { events?(.failed(.playbackFailed)) }
    }

    func setVoiceActive(_ value: Bool) async throws {
        guard !targets.isEmpty else { throw BluetoothMediaFailure.unavailable }
        voiceActive = value
        if value {
            standby?.pause(); cue?.stop()
            ownsPlaybackSession = false // The root voice owner now owns audio configuration.
        } else {
            let owner = generation
            configuringPlayback = true
            try await Self.configurePlayback()
            guard generation == owner else { throw CancellationError() }
            configuringPlayback = false; ownsPlaybackSession = true
            guard hasBluetoothOutput, !otherAudioPlaying, standby?.play() == true else {
                throw BluetoothMediaFailure.playbackFailed
            }
        }
    }

    func stop() async -> Bool {
        generation &+= 1
        events = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
        for (command, target) in targets { command.removeTarget(target) }; targets = []
        standby?.stop(); standby = nil; cue?.stop(); cue = nil
        let info = MPNowPlayingInfoCenter.default()
        if info.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == Self.title { info.nowPlayingInfo = nil }
        // Never deactivate a shared session while the VM's microphone/TTS owns it.
        if ownsPlaybackSession || configuringPlayback {
            do { try await Self.deactivatePlayback() }
            catch { return false }
        }
        ownsPlaybackSession = false; configuringPlayback = false; voiceActive = false
        return true
    }

    private nonisolated static func configurePlayback() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            audioQueue.async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    guard !session.isOtherAudioPlaying else { throw BluetoothMediaFailure.otherAudioPlaying }
                    // A deliberate, exclusive Now Playing claim. Do not claim coexistence with
                    // music: diagnostics refuses Arm while other audio is already playing.
                    try session.setCategory(.playback, mode: .default)
                    try session.setActive(true)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private nonisolated static func deactivatePlayback() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            audioQueue.async {
                do {
                    try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    /// Small PCM output buffers synthesized in memory; no recording or audio file persistence.
    private static func wav(tone: Bool) -> Data {
        let rate: UInt32 = 16_000
        let count = tone ? 1_600 : 16_000
        var data = Data()
        func ascii(_ text: String) { data.append(contentsOf: text.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            Swift.withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        ascii("RIFF"); number(UInt32(36 + count * 2)); ascii("WAVEfmt ")
        number(UInt32(16)); number(UInt16(1)); number(UInt16(1)); number(rate)
        number(rate * 2); number(UInt16(2)); number(UInt16(16)); ascii("data"); number(UInt32(count * 2))
        for index in 0..<count {
            let envelope = tone ? min(1, Double(index) / 160, Double(count - index) / 160) : 0
            let sample = Int16(sin(Double(index) * 2 * .pi * 660 / Double(rate)) * 12_000 * envelope)
            number(sample)
        }
        return data
    }
}
#else
@MainActor
final class AppleBluetoothMediaDriver: BluetoothMediaDriving {
    var hasClaim: Bool { false }
    var hasBluetoothOutput: Bool { false }
    var otherAudioPlaying: Bool { false }
    func start(events: @escaping @MainActor @Sendable (BluetoothMediaDriverEvent) -> Void) async throws { throw BluetoothMediaFailure.unavailable }
    func setVoiceActive(_ value: Bool) async throws { throw BluetoothMediaFailure.unavailable }
    func playDiagnosticCue() {}
    func stop() async -> Bool { true }
}
#endif
