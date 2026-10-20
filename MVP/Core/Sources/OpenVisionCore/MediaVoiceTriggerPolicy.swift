import Foundation

/// Public media commands carry no trusted headset/source identity. They are not DAT captouch.
public enum MediaVoiceCommand: String, CaseIterable, Sendable, Hashable {
    case play, pause, togglePlayPause, nextTrack, previousTrack
}

public enum MediaVoiceAction: String, CaseIterable, Sendable {
    case diagnosticsOnly, playPause, nextTrack, previousTrack

    public func matches(_ command: MediaVoiceCommand) -> Bool {
        switch self {
        case .diagnosticsOnly: false
        case .playPause: command == .play || command == .pause || command == .togglePlayPause
        case .nextTrack: command == .nextTrack
        case .previousTrack: command == .previousTrack
        }
    }
}

/// Coalesces Bluetooth stacks that emit more than one media event for one physical gesture.
/// Receipt time is monotonic phone time; it is never interpreted as a tap count or headset ID.
public struct MediaVoiceTriggerPolicy: Sendable {
    private var lastAccepted: UInt64?
    private let interval: UInt64
    public init(minimumIntervalNanoseconds: UInt64 = 1_000_000_000) { interval = minimumIntervalNanoseconds }
    public mutating func reset() { lastAccepted = nil }
    public mutating func accepts(_ command: MediaVoiceCommand, action: MediaVoiceAction,
                                 atNanoseconds now: UInt64) -> Bool {
        guard action.matches(command) else { return false }
        if let previous = lastAccepted {
            guard now >= previous, now - previous >= interval else { return false }
        }
        lastAccepted = now
        return true
    }
}
