import Foundation

public enum GlassesInputSource: Sendable { case captouch, captureButton, actionButton, neuralBand, unknown }
public enum GlassesInputAction: Sendable { case select, navigation, back, capture, button, drag, unknown }
public struct GlassesInputSample: Sendable {
    public let source: GlassesInputSource
    public let action: GlassesInputAction
    public let timestampMilliseconds: Int64
    public init(source: GlassesInputSource, action: GlassesInputAction, timestampMilliseconds: Int64) {
        self.source = source; self.action = action; self.timestampMilliseconds = timestampMilliseconds
    }
}

/// Only semantic captouch Select can toggle voice. Device time is used solely for ordering;
/// phone monotonic time throttles queued bursts without comparing unrelated clock epochs.
public struct GlassesVoiceInputPolicy: Sendable {
    private var epoch: UInt64?
    private var lastDeviceTimestamp: Int64?
    private var lastAcceptedReceipt: UInt64?
    private let minimumIntervalNanoseconds: UInt64
    public init(minimumIntervalNanoseconds: UInt64 = 750_000_000) { self.minimumIntervalNanoseconds = minimumIntervalNanoseconds }
    public mutating func arm(epoch: UInt64) {
        self.epoch = epoch; lastDeviceTimestamp = nil; lastAcceptedReceipt = nil
    }
    public mutating func invalidate() { epoch = nil; lastDeviceTimestamp = nil; lastAcceptedReceipt = nil }
    public mutating func shouldToggle(_ sample: GlassesInputSample, epoch: UInt64, receivedAtNanoseconds: UInt64) -> Bool {
        guard self.epoch == epoch, sample.source == .captouch, sample.action == .select,
              sample.timestampMilliseconds >= 0 else { return false }
        if let previous = lastDeviceTimestamp, sample.timestampMilliseconds <= previous { return false }
        // Record even a throttled Select so replay cannot become valid after the interval.
        lastDeviceTimestamp = sample.timestampMilliseconds
        if let previous = lastAcceptedReceipt {
            guard receivedAtNanoseconds >= previous,
                  receivedAtNanoseconds - previous >= minimumIntervalNanoseconds else { return false }
        }
        lastAcceptedReceipt = receivedAtNanoseconds
        return true
    }
}
