import Foundation

/// A turn owns its photo and cancellation identity. Images from previous turns are never reused.
public struct TurnLifecycle: Sendable {
    public enum Phase: Equatable, Sendable { case idle, listening, capturing, answering, speaking }
    public private(set) var phase: Phase = .idle
    public private(set) var turnID: UUID?
    public init() {}
    @discardableResult public mutating func begin(photo: Bool) -> UUID {
        let id = UUID()
        turnID = id
        phase = photo ? .capturing : .answering
        return id
    }
    public func isCurrent(_ id: UUID) -> Bool { turnID == id }
    @discardableResult public mutating func advance(_ id: UUID, to phase: Phase) -> Bool {
        guard isCurrent(id) else { return false }
        self.phase = phase
        return true
    }
    public mutating func listen() { turnID = nil; phase = .listening }
    public mutating func stop() { turnID = nil; phase = .idle }
}
